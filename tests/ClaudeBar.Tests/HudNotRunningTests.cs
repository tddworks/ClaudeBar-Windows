using System.Globalization;
using System.Text.Json.Nodes;
using ClaudeBar;

namespace ClaudeBar.Tests;

/// A stopped distro's tools (docs/plans/2026-11-03-wsl-design.md, The HUD,
/// Limits and Settings): its last numbers stay, dimmed, with their time.
[TestClass]
public sealed class HudNotRunningTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 14, 30, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset ReadAt = new(2026, 11, 4, 14, 5, 0, TimeSpan.Zero);

    [TestMethod]
    public void Should_count_a_tool_of_a_stopped_distro_as_stale_with_its_numbers()
    {
        var data = HudData.Parse(Reply(tool: "wsl:Ubuntu-26.04/claude", problem: ("wsl:Ubuntu-26.04/claude", "notRunning")))!;

        Assert.AreEqual("notRunning", data.Stale("wsl:Ubuntu-26.04/claude")?.Kind);
        Assert.HasCount(1, data.Summary().Rows);   // a stale tool needs the person's eye, as a failed one does
        Assert.AreEqual(ReadAt, data.Tools.Single().ReadAt);
        Assert.IsFalse(data.Alone.Any());
    }

    [TestMethod]
    public void Should_tell_Narrator_that_WSL_isn_t_running_and_the_time_of_the_numbers()
    {
        var at = ReadAt.ToLocalTime();
        var culture = CultureInfo.GetCultureInfo("en-GB");

        Assert.AreEqual($"Claude · WSL: WSL isn't running. These are its numbers from {HudText.Clock(at, culture)}.",
                        HudText.NotRunningSentence("Claude · WSL", at, culture));
        Assert.AreEqual("Claude · WSL: WSL isn't running.", HudText.NotRunningSentence("Claude · WSL", null, culture));
    }

    [TestMethod]
    public void Should_fold_a_stopped_distro_s_quiet_omp_accounts_into_one_row_as_while_it_runs()
    {
        var running = HudData.Parse(Distro(stopped: false))!;
        var stopped = HudData.Parse(Distro(stopped: true))!;

        // Running: Claude is fine (the quiet row), omp's accounts with nothing measured are one row.
        Assert.AreEqual("wsl:Ubuntu-26.04/omp", string.Join(",", running.Summary().Rows.Select(RowId)));
        Assert.IsNull(running.Summary().Rows.Single().Problem);
        // Stopped: the same tools, each saying WSL isn't running, and nothing more.
        var rows = stopped.Summary().Rows;
        Assert.AreEqual("wsl:Ubuntu-26.04/claude,wsl:Ubuntu-26.04/omp", string.Join(",", rows.Select(RowId)));
        Assert.IsTrue(rows.All(row => row.Problem?.Kind == "notRunning"));
        Assert.IsNotNull(rows[0].Headline);   // Claude keeps its numbers, dimmed, with their time
        Assert.IsNull(rows[1].Headline);
        Assert.AreEqual("Oh My Pi · WSL", stopped.LookOf(rows[1].Tool!.Id).Name);
        Assert.IsFalse(stopped.AloneOnHud.Any());
        // Limits keeps a card for each account, as while it runs, each saying WSL isn't running.
        CollectionAssert.AreEqual(new[] { Josh, Work }, stopped.Alone.Select(problem => problem.Id).ToList());
    }

    [TestMethod]
    public void Should_say_WSL_once_in_a_WSL_group_s_header()
    {
        var data = HudData.Parse(Distro(stopped: false))!;
        var named = HudData.Parse(Distro(stopped: false, place: "WSL Ubuntu-26.04"))!;

        Assert.AreEqual("Claude · josh · WSL", data.LookOf(Josh).Name);   // the HUD's row
        Assert.AreEqual("Claude · josh · WSL · via Oh My Pi", data.Header(Josh));   // Limits, Settings and Narrator
        Assert.AreEqual("Oh My Pi", data.ViaName(Josh));
        Assert.AreEqual("Claude · josh · WSL Ubuntu-26.04 · via Oh My Pi", named.Header(Josh));
        Assert.AreEqual("Claude · WSL", data.Header("wsl:Ubuntu-26.04/claude"));
        Assert.IsNull(data.ViaName("wsl:Ubuntu-26.04/claude"));
    }

    private const string Josh = "wsl:Ubuntu-26.04/omp/Claude · josh";
    private const string Work = "wsl:Ubuntu-26.04/omp/Codex · work";

    private static string RowId(HudSummary.Row row) => row.Tool?.Id ?? row.Problem!.Id;

    /// A distro as the merge sends it: Claude with numbers read at 14:05, and
    /// two omp accounts omp measures nothing for (a note alone); stopped,
    /// each of the three `notRunning`. Every name ends with its place.
    private static JsonObject Distro(bool stopped, string place = "WSL")
    {
        JsonObject Group(string id, string group) => new()
        {
            ["id"] = id, ["group"] = group, ["via"] = "wsl:Ubuntu-26.04/omp", ["lines"] = new JsonArray(),
            ["notes"] = new JsonArray(new JsonObject { ["label"] = null, ["value"] = "No usage reported", ["unit"] = "" }),
            ["outUntil"] = null, ["runningHot"] = false, ["headline"] = 0, ["others"] = new JsonObject { ["count"] = 0, ["attention"] = 0 },
        };
        JsonObject Look(string id, string name) => new() { ["id"] = id, ["name"] = $"{name} · {place}", ["light"] = "#299E61", ["dark"] = "#299E61", ["place"] = place };
        var reply = Reply(tool: "wsl:Ubuntu-26.04/claude", problem: ("wsl:Ubuntu-26.04/claude", "notRunning"));
        ((JsonArray)reply["reading"]!["tools"]!).Add(Group(Josh, "Claude · josh"));
        ((JsonArray)reply["reading"]!["tools"]!).Add(Group(Work, "Codex · work"));
        var problems = (JsonArray)reply["problems"]!;
        problems.Clear();
        if (stopped)
            foreach (var id in new[] { "wsl:Ubuntu-26.04/claude", Josh, Work }) problems.Add(new JsonObject { ["id"] = id, ["kind"] = "notRunning", ["message"] = "" });
        reply["looks"] = new JsonArray(Look("wsl:Ubuntu-26.04/claude", "Claude"), Look("wsl:Ubuntu-26.04/omp", "Oh My Pi"),
                                       Look(Josh, "Claude · josh"), Look(Work, "Codex · work"));
        // As it crosses the C interface: numbers parsed from text, as `Parse` reads them.
        return (JsonObject)JsonNode.Parse(reply.ToJsonString())!;
    }

    /// The reply of `cbw_hud_reading`, as `HudSummaryTests` builds it: one
    /// tool with one line, read at 14:05, and one problem with an empty
    /// message, as the merge sends `notRunning`.
    private static JsonObject Reply(string tool, (string Id, string Kind) problem) => (JsonObject)JsonNode.Parse(new JsonObject
    {
        ["reading"] = new JsonObject
        {
            ["tools"] = new JsonArray(new JsonObject
            {
                ["id"] = tool, ["outUntil"] = null, ["runningHot"] = false, ["headline"] = 0, ["readAt"] = ReadAt.ToUnixTimeSeconds(),
                ["others"] = new JsonObject { ["count"] = 0, ["attention"] = 0 },
                ["lines"] = new JsonArray(new JsonObject
                {
                    ["key"] = "session", ["window"] = "5h", ["percentLeft"] = 62, ["resetsAt"] = Now.AddHours(2).ToUnixTimeSeconds(),
                    ["windowSeconds"] = 18000, ["status"] = "healthy", ["runningHot"] = false, ["tick"] = 40.0, ["strip"] = true,
                }),
            }),
            ["worst"] = "healthy",
        },
        ["readAt"] = Now.ToUnixTimeSeconds(),
        ["problems"] = new JsonArray(new JsonObject { ["id"] = problem.Id, ["kind"] = problem.Kind, ["message"] = "" }),
        ["looks"] = new JsonArray(new JsonObject { ["id"] = tool, ["name"] = "Claude · WSL", ["light"] = "#E2674A", ["dark"] = "#E2674A" }),
    }.ToJsonString())!;
}
