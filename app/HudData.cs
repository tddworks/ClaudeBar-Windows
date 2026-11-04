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
                                string Status, bool RunningHot, double? Tick, bool Strip, DateTimeOffset? RunsOutAt = null, string Key = "");

    /// A note the Mac's card shows beside a tool's limits: a login's own,
    /// with its label and unit (`Credits`, `59,691`, `credits`), or a group's,
    /// its text alone (`1 saved reset · next expires Nov 7`).
    internal sealed record Note(string? Label, string Value, string Unit);

    /// A tool's limits in its own order, with the one that stops the person
    /// first (`Headline`, ClaudeBar's rule: the HUD never ranks them again),
    /// how many others there are and how many of those aren't healthy, and
    /// when its numbers were read, if the reading says; its notes, its plan's
    /// badge (`ULTRA`), and whether its notes say omp signed it out.
    internal sealed record Tool(string Id, IReadOnlyList<Line> Lines, IReadOnlyList<Note> Notes, DateTimeOffset? OutUntil, bool RunningHot,
                                int Headline = 0, int OthersCount = 0, int OthersAttention = 0, DateTimeOffset? ReadAt = null,
                                string? Group = null, string? Via = null, string? Tier = null, bool SignedOut = false)
    {
        internal Line HeadlineLine => Lines[Math.Clamp(Headline, 0, Lines.Count - 1)];

        /// A group with notes and no limit to draw: an account omp measures
        /// nothing for, a balance it writes as a note, one it signed out.
        /// Only the Limits page shows it, unless it's signed out.
        internal bool NotesOnly => Group is not null && Lines.Count == 0 && Notes.Count > 0;
    }

    /// A tool without live numbers: `reading` (not read yet), `signedOut`,
    /// `failed`, or `notRunning` (a WSL distro that isn't running; its message
    /// is empty, and the app says it with the numbers' time), and what to do
    /// about it. Such a tool may also be in `Tools` with the numbers it had
    /// (`Stale`). Tools not set up on this PC (`notSetUp`) are left out: the HUD doesn't show them.
    internal sealed record Problem(string Id, string Kind, string Message);

    /// A tool's name and colours (`#RRGGBB`), light and dark.
    internal sealed record Look(string Id, string Name, string Light, string Dark);

    internal static readonly HudData Empty = new(Array.Empty<Tool>(), "healthy", null, Array.Empty<Problem>(), Array.Empty<Look>());

    internal bool IsEmpty => Tools.Count == 0 && Problems.Count == 0;

    /// The tools the HUD draws: every one but a group of notes alone that
    /// isn't signed out (design, Notes and plans). An aggregator whose every
    /// group is such a group has nothing else to draw, so it stands in for
    /// them as itself, a tool with no limits to show, rather than vanish.
    internal IEnumerable<Tool> OnHud
    {
        get
        {
            foreach (var tool in Tools)
            {
                if (!tool.NotesOnly || tool.SignedOut) yield return tool;
                else if (tool.Via is { } via && Tools.First(other => other.Via == via) == tool && StandsIn(via))
                    yield return new Tool(via, Array.Empty<Line>(), Array.Empty<Note>(), null, false);
            }
        }
    }

    /// Whether aggregator `via` stands in for its groups (`OnHud`): it has no
    /// tool of its own (the login's limits or notes, already a row), and every
    /// one of its groups is a group of notes alone that isn't signed out.
    private bool StandsIn(string via) =>
        Tools.All(other => other.Id != via) && Tools.Where(other => other.Via == via).All(other => other.NotesOnly && !other.SignedOut);

    /// The words omp's mapping starts a signed-out account's note with, as
    /// `HudReading.signedOut` reads them: the note the HUD's row says.
    internal const string SignedOutWords = "Signed out";

    /// The problems shown on their own: a tool that still has numbers shows
    /// with them; one with no limit line to draw (balances only) has none.
    internal IEnumerable<Problem> Alone => Problems.Where(problem => Tools.All(tool => tool.Lines.Count == 0 || tool.Id != problem.Id));

    /// Why a tool's numbers aren't live: signed out, its last read failed, or
    /// its WSL distro isn't running, while the numbers it had are still here.
    internal Problem? Stale(string id) =>
        Tools.Any(tool => tool.Id == id && tool.Lines.Count > 0) ? Problems.FirstOrDefault(problem => problem.Id == id && problem.Kind is "signedOut" or "failed" or "notRunning") : null;

    /// What the HUD shows (design, What it shows): a row for each tool that
    /// needs the person, in their order (its headline not healthy or running
    /// hot, or its numbers not live), then a row for each tool without
    /// numbers (an account omp signed out among them), then one for each tool
    /// whose limits have no share to draw (`Headline` null) and is on the HUD
    /// (`OnHud`); every other tool goes into one quiet row.
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
        rows.AddRange(OnHud.Where(tool => tool.Lines.Count == 0 && Problems.All(problem => problem.Id != tool.Id))
            .Select(tool => new HudSummary.Row(tool, null, null)));
        var lowest = fine.OrderBy(tool => tool.HeadlineLine.PercentLeft).FirstOrDefault();
        var quiet = lowest is null ? null
            : new HudSummary.Quiet(fine.Select(tool => tool.Id).ToList(), lowest.Id, lowest.HeadlineLine.PercentLeft, rows.Count == 0);
        return new HudSummary(rows, quiet);
    }

    /// Every limit by a key that stays the same between readings, whatever
    /// its title: the login it was read through and ClaudeBar's own key for
    /// the quota (`claude/session`, `omp/time:Claude 5h · work`), so an
    /// aggregator's groups keep theirs and two accounts never share one.
    internal static string Key(Tool tool, Line line) => $"{tool.Via ?? tool.Id}/{line.Key}";

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
                Date(line["runsOutAt"]),
                line["key"]?.GetValue<string>() ?? line["window"]?.GetValue<string>() ?? "")).ToList(),
            (tool["notes"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(note => new Note(
                note["label"]?.GetValue<string>(), note["value"]?.GetValue<string>() ?? "", note["unit"]?.GetValue<string>() ?? "")).ToList(),
            Date(tool["outUntil"]),
            tool["runningHot"]?.GetValue<bool>() == true,
            (int)(tool["headline"]?.GetValue<double>() ?? 0),
            (int)(tool["others"]?["count"]?.GetValue<double>() ?? 0),
            (int)(tool["others"]?["attention"]?.GetValue<double>() ?? 0),
            Date(tool["readAt"]),
            tool["group"]?.GetValue<string>(),
            tool["via"]?.GetValue<string>(),
            tool["tier"]?.GetValue<string>(),
            tool["signedOut"]?.GetValue<bool>() == true)).ToList();
        var problems = (reply["problems"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(problem => new Problem(
                problem["id"]?.GetValue<string>() ?? "", problem["kind"]?.GetValue<string>() ?? "failed", problem["message"]?.GetValue<string>() ?? ""))
            .Where(problem => problem.Kind != "notSetUp").ToList();
        // An account omp signed out is a tool without live numbers, as a
        // signed-out login is, its sign-out note saying what to do (its other
        // notes stay on Limits); a problem the reading already has for it
        // (its aggregator's read failed) stays.
        problems.AddRange(tools.Where(tool => tool.SignedOut && problems.All(problem => problem.Id != tool.Id))
            .Select(tool => new Problem(tool.Id, "signedOut", string.Join("\n", tool.Notes.Where(note => note.Value.StartsWith(SignedOutWords, StringComparison.Ordinal)).Select(HudText.NoteText)))).ToList());
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

    /// A tool's name and colours: its own, or for a group without one its
    /// aggregator's colours under the group's name, or its product's for a
    /// second login (`codex.work`), or its id in grey.
    internal Look LookOf(string id) =>
        Looks.FirstOrDefault(look => look.Id == id)
        ?? (id.IndexOf('/') is > 0 and var slash ? LookOf(id[..slash]) with { Id = id, Name = id[(slash + 1)..] } : null)
        ?? Looks.FirstOrDefault(look => look.Id == id.Split('.')[0])
        ?? new Look(id, id, "#8A8A8A", "#8A8A8A");

    /// A tool's name as the Limits page and the HUD's settings say it: a group
    /// says what it was read through (`Codex · via Oh My Pi`).
    internal string Header(string id) =>
        Tools.FirstOrDefault(tool => tool.Id == id)?.Via is { } via ? $"{LookOf(id).Name} · via {LookOf(via).Name}" : LookOf(id).Name;

    /// The tools taken off the HUD, with every group of an aggregator taken
    /// off whole (`omp`, as it was hidden before its groups were tools): a
    /// group it reads later is hidden too.
    internal IReadOnlySet<string> Hidden(IReadOnlySet<string> hidden) =>
        hidden.Concat(Tools.Where(tool => tool.Via is { } via && hidden.Contains(via)).Select(tool => tool.Id)).ToHashSet();

    /// The tools taken off the HUD once `id` is back on it: a group back on
    /// takes its aggregator off the whole-hidden list, its other groups staying off.
    internal IReadOnlySet<string> Showing(IReadOnlySet<string> hidden, string id)
    {
        var via = Tools.FirstOrDefault(tool => tool.Id == id)?.Via;
        return Hidden(hidden).Where(other => other != id && other != via).ToHashSet();
    }

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

    /// Without the tools the person took off the HUD (Settings → HUD → Tools on
    /// the HUD), nor the groups of notes alone their aggregator doesn't stand
    /// in for in the whole reading: with a group that has limits taken off,
    /// the rest mustn't become a row Settings doesn't list.
    internal HudData Without(IReadOnlySet<string> hidden) => hidden.Count == 0 ? this : this with
    {
        Tools = Tools.Where(tool => !Off(hidden, tool.Id) && (!tool.NotesOnly || tool.SignedOut || tool.Via is { } via && StandsIn(via))).ToList(),
        Problems = Problems.Where(problem => !Off(hidden, problem.Id)).ToList(),
    };

    /// Whether a tool is off the HUD: by its own id, or a group (`omp/Codex`)
    /// by its aggregator's, taken off whole.
    internal static bool Off(IReadOnlySet<string> hidden, string id) =>
        hidden.Contains(id) || (id.IndexOf('/') is > 0 and var slash && hidden.Contains(id[..slash]));

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
