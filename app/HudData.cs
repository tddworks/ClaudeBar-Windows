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
    /// ahead of an even pace, where an even pace would end (0–100), and
    /// whether the strip shows it.
    internal sealed record Line(string Window, int PercentLeft, DateTimeOffset? ResetsAt, double? WindowSeconds,
                                string Status, bool RunningHot, double? Tick, bool Strip);

    internal sealed record Tool(string Id, IReadOnlyList<Line> Lines, DateTimeOffset? OutUntil, bool RunningHot);

    /// A tool without numbers, or whose last read failed: `reading` (not read
    /// yet), `signedOut` or `failed`, and what to do about it. A failed tool
    /// may also be in `Tools` with its last numbers. Tools not set up on this
    /// PC (`notSetUp`) are left out: the HUD doesn't show them.
    internal sealed record Problem(string Id, string Kind, string Message);

    /// A tool's name and colours (`#RRGGBB`), light and dark.
    internal sealed record Look(string Id, string Name, string Light, string Dark);

    internal static readonly HudData Empty = new(Array.Empty<Tool>(), "healthy", null, Array.Empty<Problem>(), Array.Empty<Look>());

    /// Nothing to show: no tool signed in.
    internal bool IsEmpty => Tools.Count == 0 && Problems.Count == 0;

    /// The tool's last read failed, if it did: its numbers are the last ones it had.
    internal Problem? Failed(string id) => Problems.FirstOrDefault(problem => problem.Id == id && problem.Kind == "failed");

    /// The problems shown on their own: a failed tool that still has numbers shows with them.
    internal IEnumerable<Problem> Alone => Problems.Where(problem => Tools.All(tool => tool.Id != problem.Id));

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
                line["strip"]?.GetValue<bool>() == true)).ToList(),
            Date(tool["outUntil"]),
            tool["runningHot"]?.GetValue<bool>() == true)).ToList();
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
            Lines = tool.Lines.Select(line => line with { ResetsAt = line.ResetsAt + by }).ToList(),
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
