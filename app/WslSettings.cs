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

    /// The group's one line when there's no distro to list: WSL isn't installed, or no distros.
    internal static string? Empty(JsonObject? wsl) =>
        wsl is null ? Looking
        : wsl["installed"]?.GetValue<bool>() != true ? NotInstalled
        : Distros(wsl).Count == 0 ? NoDistros
        : null;

    /// Each distro the reply lists, in its order. `kept` is app.json's "wsl";
    /// `windows` is this PC's time zone.
    internal static IReadOnlyList<Row> Rows(JsonObject? wsl, JsonObject kept, TimeZoneInfo windows) =>
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
                           reading is null ? Array.Empty<string>() : Notes(reading, windows),
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

    /// Its clock when it isn't Windows', and its shell's settings when they couldn't be read.
    private static IReadOnlyList<string> Notes(JsonObject reading, TimeZoneInfo windows)
    {
        var notes = new List<string>();
        if (reading["timeZone"]?.GetValue<string>() is { Length: > 0 } zone && !SameZone(zone, windows))
            notes.Add($"Its clock is {zone}; Windows' is {windows.Id}, so its days may differ from this PC's");
        if (reading["environmentImport"]?["state"]?.GetValue<string>() == "failed") notes.Add(ShellUnread);
        return notes;
    }

    /// The distro's IANA zone against Windows' own, whichever form each id has.
    private static bool SameZone(string iana, TimeZoneInfo windows) =>
        iana == windows.Id
        || TimeZoneInfo.TryConvertIanaIdToWindowsId(iana, out var windowsId) && windowsId == windows.Id
        || TimeZoneInfo.TryConvertWindowsIdToIanaId(windows.Id, out var ianaId) && ianaId == iana;

    /// A path in the distro with its home as `~`: `/home/me/.local/bin/claude` is `~/.local/bin/claude`.
    private static string Home(string path) => HomePrefix.Replace(path, "~");

    private static readonly Regex HomePrefix = new(@"^(/home/[^/]+|/root)(?=/|$)", RegexOptions.CultureInvariant);

    /// Seconds since 1970, as the C interface and app.json write them.
    private static double? Seconds(JsonNode? node) =>
        node is JsonValue value ? value.TryGetValue<double>(out var seconds) ? seconds : value.TryGetValue<long>(out var whole) ? whole : null : null;
}
