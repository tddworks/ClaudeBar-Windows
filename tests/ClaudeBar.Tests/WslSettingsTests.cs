using System.Text.Json.Nodes;
using ClaudeBar;

namespace ClaudeBar.Tests;

/// Settings → Tools in WSL (docs/plans/2026-11-03-wsl-design.md, The HUD,
/// Limits and Settings), from the reply's "wsl" and app.json's, with the
/// probe's answer the checked-in sample the Swift side reads too.
[TestClass]
public sealed class WslSettingsTests
{
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;

    // MARK: - The group's line

    [TestMethod]
    public void Should_say_when_WSL_isn_t_installed_or_has_no_distros()
    {
        Assert.AreEqual("WSL isn't installed", WslSettings.Empty(Parsed(new JsonObject { ["installed"] = false })));
        Assert.AreEqual("No distros", WslSettings.Empty(Wsl()));
        Assert.IsNull(WslSettings.Empty(Wsl(Distro())));
    }

    // MARK: - The switch

    [TestMethod]
    public void Should_turn_a_distro_on_by_default_once_its_reading_finds_a_tool()
    {
        Assert.IsTrue(Row(Wsl(Distro())).On);
        Assert.IsFalse(Row(Wsl(Distro(reading: Sample(reading => reading["tools"] = new JsonArray())))).On);
    }

    [TestMethod]
    public void Should_keep_a_distro_off_once_it_s_set_off_whatever_it_read()
    {
        var kept = Kept(new JsonObject { ["on"] = false });

        Assert.IsFalse(Row(Wsl(Distro()), kept).On);
    }

    [TestMethod]
    public void Should_keep_a_distro_on_once_it_s_set_on_with_no_tool_found()
    {
        var kept = Kept(new JsonObject { ["on"] = true });

        Assert.IsTrue(Row(Wsl(Distro(reading: Sample(reading => reading["tools"] = new JsonArray()))), kept).On);
    }

    // MARK: - What it found

    [TestMethod]
    public void Should_say_where_each_tool_is_and_which_sources_were_left_out()
    {
        var row = Row(Wsl(Distro()));

        Assert.AreEqual("Ubuntu-26.04", row.Name);
        Assert.IsTrue(row.Running);
        CollectionAssert.AreEqual(new[]
        {
            new WslSettings.Source("Claude", "~/.local/bin/claude", null),
            new WslSettings.Source(OmpName, "logs only", null),
            new WslSettings.Source("Codex", "shared with Windows", @"C:\Users\me\.codex"),
            new WslSettings.Source(UncheckableName, "couldn't check against Windows", null),
        }, row.Sources.ToList());
    }

    [TestMethod]
    public void Should_show_what_app_json_keeps_while_the_reply_has_no_reading()
    {
        var kept = Kept(new JsonObject { ["answeredAt"] = 1_762_230_000, ["reading"] = Sample() });

        var row = Row(Wsl(Distro(running: false, read: false)), kept);

        Assert.IsFalse(row.Running);
        Assert.AreEqual("~/.local/bin/claude", row.Sources[0].Where);
    }

    // MARK: - Notes

    [TestMethod]
    public void Should_note_a_clock_that_isn_t_Windows()
    {
        var row = Row(Wsl(Distro()));

        CollectionAssert.AreEqual(new[] { "Its clock is Asia/Seoul; Windows' is UTC, so its days may differ from this PC's" }, row.Notes.ToList());
    }

    [TestMethod]
    public void Should_say_nothing_of_a_clock_that_is_Windows()
    {
        var seoul = TimeZoneInfo.FindSystemTimeZoneById("Asia/Seoul");

        Assert.IsEmpty(WslSettings.Rows(Wsl(Distro()), new JsonObject(), seoul).Single().Notes);
    }

    [TestMethod]
    public void Should_note_a_shell_whose_settings_couldn_t_be_read()
    {
        var reading = Sample(reading =>
        {
            reading["timeZone"] = "UTC";
            reading["environmentImport"] = new JsonObject { ["state"] = "failed", ["names"] = new JsonArray(), ["reason"] = "timed out after 3 s" };
        });

        var row = Row(Wsl(Distro(reading: reading)));

        CollectionAssert.AreEqual(new[] { "Couldn't read your shell's settings; custom folders like CODEX_HOME may be missed" }, row.Notes.ToList());
    }

    [TestMethod]
    public void Should_say_why_the_last_run_failed()
    {
        var row = Row(Wsl(Distro(error: "ClaudeBar couldn't run in Ubuntu-26.04: libcurl.so.4: cannot open shared object file")));

        Assert.AreEqual("ClaudeBar couldn't run in Ubuntu-26.04: libcurl.so.4: cannot open shared object file", row.Error);
        Assert.IsNull(Row(Wsl(Distro())).Error);
    }

    // MARK: - What app.json keeps

    [TestMethod]
    public void Should_keep_a_newer_answer_and_the_switch()
    {
        var kept = Kept(new JsonObject { ["on"] = true, ["answeredAt"] = 1_762_220_000, ["reading"] = Sample(reading => reading["timeZone"] = "UTC") });

        var next = WslSettings.Kept(kept, Wsl(Distro(answeredAt: 1_762_230_000)));

        Assert.IsTrue(next["Ubuntu-26.04"]!["on"]!.GetValue<bool>());
        Assert.AreEqual(1_762_230_000, next["Ubuntu-26.04"]!["answeredAt"]!.GetValue<double>());
        Assert.AreEqual("Asia/Seoul", next["Ubuntu-26.04"]!["reading"]!["timeZone"]!.GetValue<string>());
    }

    [TestMethod]
    public void Should_keep_the_first_answer_of_a_distro_kept_nothing_for()
    {
        var next = WslSettings.Kept(new JsonObject(), Wsl(Distro(answeredAt: 1_762_230_000)));

        Assert.IsNull(next["Ubuntu-26.04"]!["on"]);
        Assert.AreEqual("Asia/Seoul", next["Ubuntu-26.04"]!["reading"]!["timeZone"]!.GetValue<string>());
    }

    [TestMethod]
    public void Should_change_nothing_for_an_older_answer_or_none()
    {
        var kept = Kept(new JsonObject { ["on"] = false, ["answeredAt"] = 1_762_230_000, ["reading"] = Sample(reading => reading["timeZone"] = "UTC") });

        foreach (var wsl in new[] { Wsl(Distro(answeredAt: 1_762_220_000)), Wsl(Distro(read: false)), Wsl(Distro(answeredAt: 1_762_230_000)) })
            Assert.AreEqual(kept.ToJsonString(), WslSettings.Kept(kept, wsl).ToJsonString());
    }

    [TestMethod]
    public void Should_keep_a_distro_gone_from_the_list()
    {
        var kept = Kept(new JsonObject { ["on"] = true, ["answeredAt"] = 1_762_230_000, ["reading"] = Sample() });

        Assert.AreEqual(kept.ToJsonString(), WslSettings.Kept(kept, Wsl()).ToJsonString());
        Assert.AreEqual(kept.ToJsonString(), WslSettings.Kept(kept, null).ToJsonString());
    }

    [TestMethod]
    public void Should_set_one_distro_s_switch_and_keep_its_reading()
    {
        var kept = Kept(new JsonObject { ["answeredAt"] = 1_762_230_000, ["reading"] = Sample() });

        var next = WslSettings.WithOn(kept, "Ubuntu-26.04", false);

        Assert.IsFalse(next["Ubuntu-26.04"]!["on"]!.GetValue<bool>());
        Assert.AreEqual(kept["Ubuntu-26.04"]!["reading"]!.ToJsonString(), next["Ubuntu-26.04"]!["reading"]!.ToJsonString());
        Assert.IsNull(kept["Ubuntu-26.04"]!["on"], "the kept object itself is left as it was");
        Assert.IsTrue(WslSettings.WithOn(new JsonObject(), "Debian", true)["Debian"]!["on"]!.GetValue<bool>());
    }

    // MARK: - Helpers

    /// The names the sample's looks give omp and the uncheckable source's provider.
    private static string OmpName => Look("omp");
    private static string UncheckableName => Look(((JsonObject)Sample()["skipped"]![1]!)["provider"]!.GetValue<string>());

    private static string Look(string id) =>
        (Sample()["hud"]!["looks"] as JsonArray)!.OfType<JsonObject>().FirstOrDefault(look => look["id"]!.GetValue<string>() == id)?["name"]!.GetValue<string>() ?? id;

    private static WslSettings.Row Row(JsonObject wsl, JsonObject? kept = null) => WslSettings.Rows(wsl, kept ?? new JsonObject(), Utc).Single();

    /// app.json's "wsl" with one entry for Ubuntu-26.04.
    private static JsonObject Kept(JsonObject entry) => Parsed(new JsonObject { ["Ubuntu-26.04"] = entry });

    /// The probe's answer, `tests/wsl-probe.json`, changed as a test needs.
    private static JsonObject Sample(Action<JsonObject>? change = null)
    {
        var reading = (JsonObject)JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "wsl-probe.json")))!;
        change?.Invoke(reading);
        return reading;
    }

    /// Ubuntu-26.04 in the reply: its reading (the sample unless given) and when it answered, unless `read` is false.
    private static JsonObject Distro(bool running = true, JsonObject? reading = null, bool read = true, double answeredAt = 1_762_230_000, string? error = null) => new()
    {
        ["name"] = "Ubuntu-26.04", ["running"] = running, ["on"] = null, ["probing"] = false,
        ["answeredAt"] = read ? answeredAt : null, ["reading"] = read ? reading ?? Sample() : null, ["error"] = error,
    };

    /// The reply's "wsl", as the C interface sends it: JSON text, parsed.
    private static JsonObject Wsl(params JsonObject[] distros) => Parsed(new JsonObject
    {
        ["installed"] = true, ["distros"] = new JsonArray(distros.Select(distro => (JsonNode?)distro).ToArray()),
    });

    private static JsonObject Parsed(JsonObject value) => (JsonObject)JsonNode.Parse(value.ToJsonString())!;
}
