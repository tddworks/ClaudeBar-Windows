using System.Text.Json.Nodes;

namespace ClaudeBar;

/// One reading of every signed-in tool's limits, as `cbw_hud_reading` sends
/// it (native/Sources/ClaudeBarWindows/HudReading.swift): what each limit
/// says is ClaudeBar's to decide, so the app only draws it.
internal sealed record HudData(
    IReadOnlyList<HudData.Tool> Tools,
    string Worst,
    DateTimeOffset? ReadAt,
    IReadOnlyList<HudData.Problem> Problems,
    IReadOnlyList<HudData.Look> Looks)
{
    /// One limit: its window (`5h`), the whole percent left, its reset, the
    /// window's length, its status under the person's policy, whether it's
    /// ahead of an even pace, where an even pace would end (0–100), whether
    /// the strip shows it, and when it runs out at this pace, if the reading says.
    internal sealed record Line(string Window, int PercentLeft, DateTimeOffset? ResetsAt, double? WindowSeconds,
                                string Status, bool RunningHot, double? Tick, bool Strip, DateTimeOffset? RunsOutAt = null);

    /// A tool's limits in its own order, with the one that stops the person
    /// first (`Headline`, ClaudeBar's rule: the HUD never ranks them again),
    /// how many others there are and how many of those aren't healthy, and
    /// when its numbers were read, if the reading says.
    internal sealed record Tool(string Id, IReadOnlyList<Line> Lines, DateTimeOffset? OutUntil, bool RunningHot,
                                int Headline = 0, int OthersCount = 0, int OthersAttention = 0, DateTimeOffset? ReadAt = null)
    {
        internal Line HeadlineLine => Lines[Math.Clamp(Headline, 0, Lines.Count - 1)];
    }

    /// A tool without live numbers: `reading` (not read yet), `signedOut` or
    /// `failed`, and what to do about it. A signed-out or failed tool may also
    /// be in `Tools` with the numbers it had (`Stale`). Tools not set up on this
    /// PC (`notSetUp`) are left out: the HUD doesn't show them.
    internal sealed record Problem(string Id, string Kind, string Message);

    /// A tool's name and colours (`#RRGGBB`), light and dark.
    internal sealed record Look(string Id, string Name, string Light, string Dark);

    internal static readonly HudData Empty = new(Array.Empty<Tool>(), "healthy", null, Array.Empty<Problem>(), Array.Empty<Look>());

    /// Nothing to show: no tool signed in.
    internal bool IsEmpty => Tools.Count == 0 && Problems.Count == 0;

    /// The problems shown on their own: a tool that still has numbers shows
    /// with them; one with no limit line to draw (balances only) has none.
    internal IEnumerable<Problem> Alone => Problems.Where(problem => Tools.All(tool => tool.Lines.Count == 0 || tool.Id != problem.Id));

    /// Why a tool's numbers aren't live: signed out, or its last read failed,
    /// while the numbers it had are still here.
    internal Problem? Stale(string id) =>
        Tools.Any(tool => tool.Id == id && tool.Lines.Count > 0) ? Problems.FirstOrDefault(problem => problem.Id == id && problem.Kind is "signedOut" or "failed") : null;

    /// What the HUD shows (design, What it shows): a row for each tool that
    /// needs the person, in their order (its headline not healthy or running
    /// hot, or its numbers not live), then a row for each tool without
    /// numbers, then one for each tool whose limits have no share to draw
    /// (`Headline` null); every other tool goes into one quiet row.
    internal HudSummary Summary()
    {
        var rows = new List<HudSummary.Row>();
        var fine = new List<Tool>();
        foreach (var tool in Tools.Where(tool => tool.Lines.Count > 0))
        {
            var headline = tool.HeadlineLine;
            var stale = Stale(tool.Id);
            if (stale is not null || headline.Status != "healthy" || headline.RunningHot) rows.Add(new HudSummary.Row(tool, headline, stale));
            else fine.Add(tool);
        }
        rows.AddRange(Alone.Select(problem => new HudSummary.Row(null, null, problem)));
        rows.AddRange(Tools.Where(tool => tool.Lines.Count == 0 && Problems.All(problem => problem.Id != tool.Id))
            .Select(tool => new HudSummary.Row(tool, null, null)));
        var lowest = fine.OrderBy(tool => tool.HeadlineLine.PercentLeft).FirstOrDefault();
        var quiet = lowest is null ? null
            : new HudSummary.Quiet(fine.Select(tool => tool.Id).ToList(), lowest.Id, lowest.HeadlineLine.PercentLeft, rows.Count == 0);
        return new HudSummary(rows, quiet);
    }

    /// Every limit by a key that stays the same between readings: `claude/5h`.
    internal static string Key(Tool tool, Line line) => $"{tool.Id}/{line.Window}";

    /// The reply's reading, or null when it has none (it failed).
    internal static HudData? Parse(JsonObject reply)
    {
        if (reply["reading"] is not JsonObject reading) return null;
        var tools = (reading["tools"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(tool => new Tool(
            tool["id"]?.GetValue<string>() ?? "",
            (tool["lines"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(line => new Line(
                line["window"]?.GetValue<string>() ?? "",
                (int)(line["percentLeft"]?.GetValue<double>() ?? 0),
                Date(line["resetsAt"]),
                line["windowSeconds"]?.GetValue<double>(),
                line["status"]?.GetValue<string>() ?? "healthy",
                line["runningHot"]?.GetValue<bool>() == true,
                line["tick"]?.GetValue<double>(),
                line["strip"]?.GetValue<bool>() == true,
                Date(line["runsOutAt"]))).ToList(),
            Date(tool["outUntil"]),
            tool["runningHot"]?.GetValue<bool>() == true,
            (int)(tool["headline"]?.GetValue<double>() ?? 0),
            (int)(tool["others"]?["count"]?.GetValue<double>() ?? 0),
            (int)(tool["others"]?["attention"]?.GetValue<double>() ?? 0),
            Date(tool["readAt"]))).ToList();
        var problems = (reply["problems"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(problem => new Problem(
                problem["id"]?.GetValue<string>() ?? "", problem["kind"]?.GetValue<string>() ?? "failed", problem["message"]?.GetValue<string>() ?? ""))
            .Where(problem => problem.Kind != "notSetUp").ToList();
        // The tools' own looks first, then the Leaderboard's providers for any they don't name.
        var looks = new List<Look>();
        foreach (var node in (reply["looks"] as JsonArray ?? new JsonArray()).Concat(reply["state"]?["providers"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
        {
            var id = node["id"]?.GetValue<string>() ?? "";
            if (looks.Any(look => look.Id == id)) continue;
            looks.Add(new Look(id, node["name"]?.GetValue<string>() ?? id, node["light"]?.GetValue<string>() ?? "#8A8A8A", node["dark"]?.GetValue<string>() ?? "#8A8A8A"));
        }
        return new HudData(tools, reading["worst"]?.GetValue<string>() ?? "healthy", Date(reply["readAt"]), problems, looks);
    }

    /// A tool's name and colours: its own, or its product's for a second login
    /// (`codex.work`), or its id in grey.
    internal Look LookOf(string id) =>
        Looks.FirstOrDefault(look => look.Id == id)
        ?? Looks.FirstOrDefault(look => look.Id == id.Split('.')[0])
        ?? new Look(id, id, "#8A8A8A", "#8A8A8A");

    /// The same reading with every date moved by `by`: the check's sample, read now.
    internal HudData Shifted(TimeSpan by) => this with
    {
        ReadAt = ReadAt + by,
        Tools = Tools.Select(tool => tool with
        {
            OutUntil = tool.OutUntil + by,
            ReadAt = tool.ReadAt + by,
            Lines = tool.Lines.Select(line => line with { ResetsAt = line.ResetsAt + by, RunsOutAt = line.RunsOutAt + by }).ToList(),
        }).ToList(),
    };

    /// Without the tools the person took off the HUD (Settings → HUD → Tools on the HUD).
    internal HudData Without(IReadOnlySet<string> hidden) => hidden.Count == 0 ? this : this with
    {
        Tools = Tools.Where(tool => !hidden.Contains(tool.Id)).ToList(),
        Problems = Problems.Where(problem => !hidden.Contains(problem.Id)).ToList(),
    };

    /// Dates cross the C interface as seconds since 1970.
    private static DateTimeOffset? Date(JsonNode? node) =>
        node?.GetValue<double>() is double seconds ? DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(seconds * 1000)) : null;
}

/// The HUD's rows (HudData.Summary): the tools that need the person, and the
/// quiet row of every fine tool, with the lowest of them; `All` when that's
/// every tool.
internal sealed record HudSummary(IReadOnlyList<HudSummary.Row> Rows, HudSummary.Quiet? Fine)
{
    /// A tool with numbers (its headline, and why they aren't live, if they
    /// aren't), a tool without (`Tool` null: its problem), or a tool whose
    /// limits have no share to draw (`Headline` and `Problem` null).
    internal sealed record Row(HudData.Tool? Tool, HudData.Line? Headline, HudData.Problem? Problem);

    internal sealed record Quiet(IReadOnlyList<string> Ids, string LowestId, int LowestPercent, bool All);
}
