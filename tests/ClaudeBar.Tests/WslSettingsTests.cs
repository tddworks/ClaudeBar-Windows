using System.Text.Json.Nodes;
using ClaudeBar;

namespace ClaudeBar.Tests;

/// Settings → Tools in WSL (docs/plans/2026-11-03-wsl-design.md, The HUD,
/// Limits and Settings), from the reply's "wsl" and app.json's, with the
/// probe's answer the checked-in sample the Swift side reads too.
[TestClass]
public sealed class WslSettingsTests
{
    /// `cbw_state`'s providers, id to name, as the window keeps them (`_providers`).
    private static readonly IReadOnlyDictionary<string, string> Names = new Dictionary<string, string>
    {
        ["claude"] = "Claude", ["codex"] = "Codex", ["omp"] = "Oh My Pi",
    };

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
    public void Should_say_nothing_of_the_distro_s_own_clock()
    {
        Assert.IsEmpty(Row(Wsl(Distro(reading: Sample(reading => reading["timeZone"] = "America/Los_Angeles")))).Notes);
    }

    [TestMethod]
    public void Should_say_when_a_distro_has_no_data_for_Windows_zone()
    {
        foreach (var days in new Action<JsonObject>[] { reading => reading["days"] = null, reading => reading.Remove("days") })
        {
            var refused = Sample(reading =>
            {
                days(reading);
                reading["diagnostics"] = new JsonArray("no time zone data for Asia/Kolkata (/usr/share/zoneinfo/Asia/Kolkata)");
            });

            var row = Row(Wsl("Asia/Kolkata", Distro(reading: refused)));

            CollectionAssert.AreEqual(new[] { "No time zone data for Asia/Kolkata in Ubuntu-26.04, so its days aren't on the Leaderboard; installing tzdata in it fixes this" }, row.Notes.ToList());
        }
    }

    [TestMethod]
    public void Should_say_when_the_distro_s_reader_doesn_t_know_Windows_zone()
    {
        foreach (var diagnostic in new[] { "no time zone named Asia/Kolkata", "TZ Asia/Kolkata isn't a zone name", "something else" })
        {
            var refused = Sample(reading =>
            {
                reading.Remove("days");
                reading["diagnostics"] = new JsonArray(diagnostic);
            });

            var row = Row(Wsl("Asia/Kolkata", Distro(reading: refused)));

            CollectionAssert.AreEqual(new[] { "ClaudeBar in Ubuntu-26.04 doesn't know the time zone Asia/Kolkata, so its days aren't on the Leaderboard; an update of ClaudeBar may fix this" }, row.Notes.ToList());
        }
    }

    [TestMethod]
    public void Should_say_when_a_distro_s_kept_days_couldn_t_start_over()
    {
        var reading = Sample(reading =>
        {
            reading.Remove("days");
            reading["diagnostics"] = new JsonArray("couldn't start the kept days over for Asia/Seoul: /home/me/.claudebar/usage-history/claude.json: Permission denied");
        });

        var row = Row(Wsl(Distro(reading: reading)));

        CollectionAssert.AreEqual(new[] { "ClaudeBar couldn't start Ubuntu-26.04's kept days over for Asia/Seoul (/home/me/.claudebar/usage-history/claude.json: Permission denied), so its days aren't on the Leaderboard; once ClaudeBar can change that file, its next run counts them" }, row.Notes.ToList());
    }

    [TestMethod]
    public void Should_say_when_Windows_zone_has_no_name_Linux_knows()
    {
        var row = Row(Wsl((string?)null, Distro()));

        CollectionAssert.AreEqual(new[] { "Windows' time zone has no name Linux knows, so WSL days aren't on the Leaderboard" }, row.Notes.ToList());
    }

    [TestMethod]
    public void Should_say_only_that_Windows_zone_has_no_name_when_a_distro_s_days_were_refused_too()
    {
        var refused = Sample(reading =>
        {
            reading.Remove("days");
            reading["diagnostics"] = new JsonArray("no time zone data for Asia/Kolkata (/usr/share/zoneinfo/Asia/Kolkata)");
        });

        var row = Row(Wsl((string?)null, Distro(reading: refused)));

        CollectionAssert.AreEqual(new[] { WslSettings.NoZoneName }, row.Notes.ToList());
    }

    [TestMethod]
    public void Should_say_which_distros_read_a_log_folder_too_with_or_without_a_reading()
    {
        var rows = WslSettings.Rows(Reply(), new JsonObject(), Names);

        CollectionAssert.AreEqual(new[] { "Alpine", "Debian", "Ubuntu-26.04" }, rows.Select(row => row.Name).ToList());
        Assert.IsEmpty(rows[0].Notes);
        CollectionAssert.AreEqual(new[] { @"Claude's logs in D:\shared\.claude\projects are Ubuntu-26.04's too, so each day counts once on the Leaderboard" }, rows[1].Notes.ToList());
        CollectionAssert.AreEqual(new[] { @"Claude's logs in D:\shared\.claude are Debian's too, so each day counts once on the Leaderboard" }, rows[2].Notes.ToList());
    }

    [TestMethod]
    public void Should_name_every_distro_of_a_group_and_a_provider_by_its_id_when_it_has_no_name()
    {
        var distro = Distro();
        distro["sharedLogs"] = new JsonArray(
            new JsonObject { ["provider"] = "claude", ["windowsPath"] = @"D:\shared\.claude", ["with"] = new JsonArray("Alpine", "Debian") },
            new JsonObject { ["provider"] = "kimi", ["windowsPath"] = @"D:\shared\.kimi", ["with"] = new JsonArray("Debian") });

        var row = Row(Wsl(distro));

        CollectionAssert.AreEqual(new[]
        {
            @"Claude's logs in D:\shared\.claude are Alpine's and Debian's too, so each day counts once on the Leaderboard",
            @"kimi's logs in D:\shared\.kimi are Debian's too, so each day counts once on the Leaderboard",
        }, row.Notes.ToList());
    }

    [TestMethod]
    public void Should_list_the_zone_note_then_the_shared_logs_then_the_shell()
    {
        var reading = Sample(reading =>
        {
            reading.Remove("days");
            reading["diagnostics"] = new JsonArray("no time zone named Asia/Seoul");
            reading["environmentImport"] = new JsonObject { ["state"] = "failed", ["names"] = new JsonArray(), ["reason"] = "timed out after 3 s" };
        });
        var distro = Distro(reading: reading);
        distro["sharedLogs"] = new JsonArray(new JsonObject { ["provider"] = "omp", ["windowsPath"] = @"D:\shared\.omp", ["with"] = new JsonArray("Debian") });

        CollectionAssert.AreEqual(new[]
        {
            WslSettings.UnknownZone("Asia/Seoul", "Ubuntu-26.04"),
            WslSettings.SharedLogs("Oh My Pi", @"D:\shared\.omp", new[] { "Debian" }),
            WslSettings.ShellUnread,
        }, Row(Wsl(distro)).Notes.ToList());
    }

    [TestMethod]
    public void Should_join_names_as_a_sentence_does()
    {
        Assert.AreEqual("", WslSettings.Join(Array.Empty<string>()));
        Assert.AreEqual("A", WslSettings.Join(new[] { "A" }));
        Assert.AreEqual("A and B", WslSettings.Join(new[] { "A", "B" }));
        Assert.AreEqual("A, B and C", WslSettings.Join(new[] { "A", "B", "C" }));
    }

    // MARK: - The Leaderboard notice

    [TestMethod]
    public void Should_tell_which_shared_providers_in_which_distros_add_their_days()
    {
        var notice = WslSettings.Board(Reply(), State());

        Assert.AreEqual(new WslSettings.BoardNotice("WSL days now count on the Leaderboard",
            "Claude and Oh My Pi in Ubuntu-26.04 add their days to this PC's, as you share them. To stop adding a distro's new days, turn it off in Settings → Tools in WSL."), notice);
        Assert.AreEqual(WslSettings.BoardTitle, notice!.Title);
    }

    [TestMethod]
    public void Should_tell_of_one_provider_as_one()
    {
        var notice = WslSettings.Board(Reply(), State(omp: false));

        Assert.AreEqual("Claude in Ubuntu-26.04 adds its days to this PC's, as you share it. To stop adding a distro's new days, turn it off in Settings → Tools in WSL.", notice!.Message);
    }

    [TestMethod]
    public void Should_name_the_providers_in_Settings_order_and_the_distros_in_ordinal_order()
    {
        var notice = WslSettings.Board(Reply(), State(codex: true));

        Assert.AreEqual("Claude, Codex and Oh My Pi in Debian and Ubuntu-26.04 add their days to this PC's, as you share them. To stop adding a distro's new days, turn it off in Settings → Tools in WSL.", notice!.Message);
    }

    [TestMethod]
    public void Should_tell_nothing_unless_joined_with_a_shared_provider_the_Leaderboard_counts_from_WSL()
    {
        var empty = Reply();
        empty["leaderboard"] = new JsonArray();
        var missing = Reply();
        missing.Remove("leaderboard");
        var notJoined = State();
        notJoined["joined"] = false;

        Assert.IsNull(WslSettings.Board(Reply(), notJoined));
        Assert.IsNull(WslSettings.Board(Reply(), State(claude: false, omp: false)));
        Assert.IsNull(WslSettings.Board(empty, State()));
        Assert.IsNull(WslSettings.Board(missing, State()));
        Assert.IsNull(WslSettings.Board(null, State()));
        Assert.IsNull(WslSettings.Board(Reply(), null));
    }

    [TestMethod]
    public void Should_open_the_bar_only_until_it_has_been_shown()
    {
        var notice = WslSettings.Board(Reply(), State());

        Assert.IsTrue(WslSettings.BoardBarOpens(notice, null));
        Assert.IsFalse(WslSettings.BoardBarOpens(notice, "shown"));
        Assert.IsFalse(WslSettings.BoardBarOpens(notice, "seen"));
        Assert.IsFalse(WslSettings.BoardBarOpens(null, null));
    }

    [TestMethod]
    public void Should_show_the_Settings_note_until_it_has_been_seen()
    {
        var notice = WslSettings.Board(Reply(), State());

        Assert.IsTrue(WslSettings.BoardNoteShows(notice, null));
        Assert.IsTrue(WslSettings.BoardNoteShows(notice, "shown"));
        Assert.IsFalse(WslSettings.BoardNoteShows(notice, "seen"));
        Assert.IsFalse(WslSettings.BoardNoteShows(null, null));
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

    private static WslSettings.Row Row(JsonObject wsl, JsonObject? kept = null) => WslSettings.Rows(wsl, kept ?? new JsonObject(), Names).Single();

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

    /// The reply's "wsl", as the C interface sends it: JSON text, parsed. Windows' zone is Asia/Seoul.
    private static JsonObject Wsl(params JsonObject[] distros) => Wsl("Asia/Seoul", distros);

    /// The reply's "wsl" with Windows' zone as the app sends it: null when it has no name.
    private static JsonObject Wsl(string? timeZone, params JsonObject[] distros) => Parsed(new JsonObject
    {
        ["installed"] = true, ["distros"] = new JsonArray(distros.Select(distro => (JsonNode?)distro).ToArray()),
        ["leaderboard"] = new JsonArray(), ["timeZone"] = timeZone,
    });

    /// `tests/wsl-reply.json`: three distros, two log folders shared, and what the Leaderboard counts from them.
    private static JsonObject Reply() => (JsonObject)JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "wsl-reply.json")))!;

    /// `cbw_state`'s reply, joined, with its providers in Settings' order and each one's sharing.
    private static JsonObject State(bool claude = true, bool codex = false, bool omp = true) => Parsed(new JsonObject
    {
        ["joined"] = true,
        ["providers"] = new JsonArray(
            new JsonObject { ["id"] = "claude", ["name"] = "Claude", ["shared"] = claude },
            new JsonObject { ["id"] = "codex", ["name"] = "Codex", ["shared"] = codex },
            new JsonObject { ["id"] = "omp", ["name"] = "Oh My Pi", ["shared"] = omp }),
    });

    private static JsonObject Parsed(JsonObject value) => (JsonObject)JsonNode.Parse(value.ToJsonString())!;
}
