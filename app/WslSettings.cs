using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ClaudeBar;

/// Settings → Tools in WSL (docs/plans/2026-11-03-wsl-design.md), from the
/// HUD reply's "wsl" and what app.json keeps for each distro: its switch,
/// and its last reading with when it answered (`answeredAt`, seconds since 1970).
internal static class WslSettings
{
    /// A tool the distro's last reading found, or a source it left out: where
    /// it is (`~/.local/bin/claude`, `logs only`, `shared with Windows`), and
    /// the Windows folder it shares, if it does.
    internal sealed record Source(string Tool, string Where, string? Note);

    /// One distro: whether it runs, whether ClaudeBar reads it, what its last
    /// reading found, what to know about it, and why its last run failed.
    internal sealed record Row(string Name, bool Running, bool On, IReadOnlyList<Source> Sources, IReadOnlyList<string> Notes, string? Error);

    internal const string NotInstalled = "WSL isn't installed";
    internal const string NoDistros = "No distros";
    internal const string Looking = "Looking for WSL distros…";
    internal const string SharedWithWindows = "shared with Windows";
    internal const string Uncheckable = "couldn't check against Windows";
    internal const string LogsOnly = "logs only";
    internal const string ShellUnread = "Couldn't read your shell's settings; custom folders like CODEX_HOME may be missed";

    /// The Leaderboard notice (design, The person is told once): the bar, and the same words in Settings.
    internal sealed record BoardNotice(string Title, string Message);

    internal const string BoardTitle = "WSL days now count on the Leaderboard";
    internal const string NoZoneName = "Windows' time zone has no name Linux knows, so WSL days aren't on the Leaderboard";

    /// `TZ` names no file in the distro: tzdata would add it.
    internal static string NoZoneData(string zone, string distro) =>
        $"No time zone data for {zone} in {distro}, so its days aren't on the Leaderboard; installing tzdata in it fixes this";

    /// The file is there but the probe's Foundation doesn't know it, or `TZ` isn't a plain name: tzdata wouldn't fix it.
    internal static string UnknownZone(string zone, string distro) =>
        $"ClaudeBar in {distro} doesn't know the time zone {zone}, so its days aren't on the Leaderboard; an update of ClaudeBar may fix this";

    /// `detail` is the probe's `<path>: <strerror>`; without one, no file is named.
    internal static string NotStartedOver(string distro, string zone, string detail) => detail.Length == 0
        ? $"ClaudeBar couldn't start {distro}'s kept days over for {zone}, so its days aren't on the Leaderboard; once ClaudeBar can change its kept days, its next run counts them"
        : $"ClaudeBar couldn't start {distro}'s kept days over for {zone} ({detail}), so its days aren't on the Leaderboard; once ClaudeBar can change that file, its next run counts them";

    /// A log root of the distro's that other distros read too; `with` by name.
    internal static string SharedLogs(string provider, string path, IReadOnlyList<string> with) =>
        $"{provider}'s logs in {path} are {Join(with.Select(distro => distro + "'s").ToList())} too, so each day counts once on the Leaderboard";

    /// Names as a sentence lists them: `A`, `A and B`, `A, B and C`.
    internal static string Join(IReadOnlyList<string> names) =>
        names.Count <= 1 ? string.Concat(names) : $"{string.Join(", ", names.Take(names.Count - 1))} and {names[^1]}";

    /// What the Leaderboard counts from WSL now, said once: while joined, and a
    /// shared provider has days the reply's "leaderboard" lists. `state` is `cbw_state`'s reply.
    internal static BoardNotice? Board(JsonObject? wsl, JsonObject? state)
    {
        if (wsl is null || state is null || state["joined"]?.GetValue<bool>() != true) return null;
        var counted = (wsl["leaderboard"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .Select(entry => (Distro: entry["distro"]?.GetValue<string>() ?? "",
                              Providers: (entry["providers"] as JsonArray ?? new JsonArray()).Select(id => id?.GetValue<string>()).OfType<string>().ToHashSet()))
            .ToList();
        var shared = (state["providers"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .Where(provider => provider["shared"]?.GetValue<bool>() == true && provider["id"]?.GetValue<string>() is { } id && counted.Any(entry => entry.Providers.Contains(id)))
            .Select(provider => (Id: provider["id"]!.GetValue<string>(), Name: provider["name"]?.GetValue<string>() ?? provider["id"]!.GetValue<string>()))
            .ToList();
        if (shared.Count == 0) return null;
        var distros = counted.Where(entry => shared.Any(provider => entry.Providers.Contains(provider.Id))).Select(entry => entry.Distro)
            .Distinct().Order(StringComparer.Ordinal).ToList();
        var adds = shared.Count == 1 ? "adds its days to this PC's, as you share it" : "add their days to this PC's, as you share them";
        return new BoardNotice(BoardTitle,
            $"{Join(shared.Select(provider => provider.Name).ToList())} in {Join(distros)} {adds}. To stop adding a distro's new days, turn it off in Settings → Tools in WSL.");
    }

    /// The bar opens once: until app.json's "wslBoardNotice" says it was shown, or seen.
    internal static bool BoardBarOpens(BoardNotice? notice, string? stored) => notice is not null && stored is null;

    /// The note in Settings stays until the person closes either copy or changes a switch ("seen").
    internal static bool BoardNoteShows(BoardNotice? notice, string? stored) => notice is not null && stored != "seen";

    /// The group's one line when there's no distro to list: WSL isn't installed, or no distros.
    internal static string? Empty(JsonObject? wsl) =>
        wsl is null ? Looking
        : wsl["installed"]?.GetValue<bool>() != true ? NotInstalled
        : Distros(wsl).Count == 0 ? NoDistros
        : null;

    /// Each distro the reply lists, in its order. `kept` is app.json's "wsl";
    /// `names` is each provider's name by id, from `cbw_state`.
    internal static IReadOnlyList<Row> Rows(JsonObject? wsl, JsonObject kept, IReadOnlyDictionary<string, string> names) =>
        wsl is null ? Array.Empty<Row>() : Distros(wsl).Select(distro =>
        {
            var name = distro["name"]?.GetValue<string>() ?? "";
            var mine = kept[name] as JsonObject;
            var reading = distro["reading"] as JsonObject ?? mine?["reading"] as JsonObject;
            var tools = reading?["tools"] as JsonArray ?? new JsonArray();
            // The switch is on once it's set on, or until it's set, while the last reading found a tool.
            var on = (mine?["on"] ?? distro["on"])?.GetValue<bool>() ?? tools.Count > 0;
            return new Row(name, distro["running"]?.GetValue<bool>() == true, on,
                           reading is null ? Array.Empty<Source>() : Sources(reading),
                           Notes(reading, name, wsl, distro, names),
                           distro["error"]?.GetValue<string>());
        }).ToList();

    /// app.json's "wsl" with each newer answer in the reply kept, and every
    /// switch as it was. A distro gone from the list keeps what's kept: it may be back.
    internal static JsonObject Kept(JsonObject kept, JsonObject? wsl)
    {
        var next = (JsonObject)kept.DeepClone();
        if (wsl is null) return next;
        foreach (var distro in Distros(wsl))
        {
            if (distro["name"]?.GetValue<string>() is not { } name || distro["reading"] is not JsonObject reading
                || Seconds(distro["answeredAt"]) is not { } answeredAt) continue;
            if (next[name] is not JsonObject entry) next[name] = entry = new JsonObject();
            if (Seconds(entry["answeredAt"]) is { } before && before >= answeredAt) continue;
            entry["answeredAt"] = answeredAt;
            entry["reading"] = reading.DeepClone();
        }
        return next;
    }

    /// app.json's "wsl" with one distro's switch set, its reading kept.
    internal static JsonObject WithOn(JsonObject kept, string distro, bool on)
    {
        var next = (JsonObject)kept.DeepClone();
        if (next[distro] is not JsonObject entry) next[distro] = entry = new JsonObject();
        entry["on"] = on;
        return next;
    }

    /// The distros' names in the reply, for the update's hold.
    internal static IReadOnlyList<string> Names(JsonObject? wsl) =>
        wsl is null ? Array.Empty<string>() : Distros(wsl).Select(distro => distro["name"]?.GetValue<string>()).OfType<string>().ToList();

    private static IReadOnlyList<JsonObject> Distros(JsonObject wsl) => (wsl["distros"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();

    /// Each tool and where it was found, then each source left out and why.
    private static IReadOnlyList<Source> Sources(JsonObject reading)
    {
        var looks = (reading["hud"]?["looks"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .Where(look => look["id"] is not null).GroupBy(look => look["id"]!.GetValue<string>())
            .ToDictionary(group => group.Key, group => group.First()["name"]?.GetValue<string>());
        string Name(string id) => looks.GetValueOrDefault(id) ?? id;
        var sources = new List<Source>();
        foreach (var tool in (reading["tools"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
        {
            var id = tool["id"]?.GetValue<string>() ?? "";
            sources.Add(new Source(Name(id), tool["cli"]?.GetValue<string>() is { } cli ? Home(cli) : LogsOnly, null));
        }
        foreach (var skip in (reading["skipped"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
        {
            var id = skip["provider"]?.GetValue<string>() ?? "";
            sources.Add(skip["reason"]?.GetValue<string>() == "shared"
                ? new Source(Name(id), SharedWithWindows, skip["windowsPath"]?.GetValue<string>())
                : new Source(Name(id), Uncheckable, null));
        }
        return sources;
    }

    /// Why its days aren't on the Leaderboard, if they aren't; each log folder
    /// another distro reads too; and its shell's settings when they couldn't be read.
    private static IReadOnlyList<string> Notes(JsonObject? reading, string name, JsonObject wsl, JsonObject distro, IReadOnlyDictionary<string, string> names)
    {
        var notes = new List<string>();
        if (wsl["timeZone"]?.GetValue<string>() is not { } windows) notes.Add(NoZoneName);
        else if (reading is not null && reading["days"] is null)
        {
            var diagnostics = (reading["diagnostics"] as JsonArray ?? new JsonArray()).Select(line => line?.GetValue<string>()).OfType<string>().ToList();
            if (diagnostics.FirstOrDefault(line => line.StartsWith(NotStartedOverPrefix, StringComparison.Ordinal)) is { } failed)
            {
                // `<zone>: <path>: <strerror>`: the zone is up to the first `: `.
                var rest = failed[NotStartedOverPrefix.Length..];
                var colon = rest.IndexOf(": ", StringComparison.Ordinal);
                notes.Add(colon < 0 ? NotStartedOver(name, rest, "") : NotStartedOver(name, rest[..colon], rest[(colon + 2)..]));
            }
            else if (diagnostics.Any(line => line.StartsWith("no time zone data for ", StringComparison.Ordinal))) notes.Add(NoZoneData(windows, name));
            else notes.Add(UnknownZone(windows, name));
        }
        foreach (var shared in (distro["sharedLogs"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
        {
            var provider = shared["provider"]?.GetValue<string>() ?? "";
            notes.Add(SharedLogs(names.GetValueOrDefault(provider) ?? provider, shared["windowsPath"]?.GetValue<string>() ?? "",
                                 (shared["with"] as JsonArray ?? new JsonArray()).Select(other => other?.GetValue<string>()).OfType<string>().ToList()));
        }
        if (reading?["environmentImport"]?["state"]?.GetValue<string>() == "failed") notes.Add(ShellUnread);
        return notes;
    }

    private const string NotStartedOverPrefix = "couldn't start the kept days over for ";

    /// A path in the distro with its home as `~`: `/home/me/.local/bin/claude` is `~/.local/bin/claude`.
    private static string Home(string path) => HomePrefix.Replace(path, "~");

    private static readonly Regex HomePrefix = new(@"^(/home/[^/]+|/root)(?=/|$)", RegexOptions.CultureInvariant);

    /// Seconds since 1970, as the C interface and app.json write them.
    private static double? Seconds(JsonNode? node) =>
        node is JsonValue value ? value.TryGetValue<double>(out var seconds) ? seconds : value.TryGetValue<long>(out var whole) ? whole : null : null;
}
