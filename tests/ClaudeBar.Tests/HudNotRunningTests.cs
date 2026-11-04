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
