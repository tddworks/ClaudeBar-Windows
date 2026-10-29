using System.Globalization;
using System.Text.Json.Nodes;
using ClaudeBar;

namespace ClaudeBar.Tests;

/// What the HUD shows (docs/plans/2026-10-13-hud-design.md, What it shows):
/// a row for each tool that needs you, every fine tool in one quiet row.
[TestClass]
public sealed class HudSummaryTests
{
    private static readonly DateTimeOffset Now = new(new DateTime(2026, 10, 13, 12, 0, 0, DateTimeKind.Local));

    private static JsonObject Line(string window, int percent, string status = "healthy", bool hot = false) => new()
    {
        ["window"] = window, ["percentLeft"] = percent, ["resetsAt"] = Now.AddHours(2).ToUnixTimeSeconds(),
        ["windowSeconds"] = 18000, ["status"] = status, ["runningHot"] = hot, ["tick"] = 40.0, ["strip"] = true,
    };

    private static JsonObject Tool(string id, int headline, params JsonObject[] lines) => new()
    {
        ["id"] = id, ["lines"] = new JsonArray(lines.Select(line => (JsonNode?)line).ToArray()), ["outUntil"] = null,
        ["runningHot"] = lines.Any(line => line["runningHot"]!.GetValue<bool>()), ["headline"] = headline,
        ["others"] = new JsonObject
        {
            ["count"] = lines.Length - 1,
            ["attention"] = lines.Where((_, index) => index != headline).Count(line => line["status"]!.GetValue<string>() != "healthy"),
        },
    };

    /// The reply as it crosses the C interface: JSON text, parsed.
    private static HudData Read(JsonObject[] tools, params (string Id, string Kind)[] problems) => HudData.Parse((JsonObject)JsonNode.Parse(new JsonObject
    {
        ["reading"] = new JsonObject { ["tools"] = new JsonArray(tools.Select(tool => (JsonNode?)tool).ToArray()), ["worst"] = "healthy" },
        ["readAt"] = Now.ToUnixTimeSeconds(),
        ["problems"] = new JsonArray(problems.Select(problem => (JsonNode?)new JsonObject
        {
            ["id"] = problem.Id, ["kind"] = problem.Kind, ["message"] = "Sign in again.",
        }).ToArray()),
        ["looks"] = new JsonArray(),
    }.ToJsonString())!)!;

    [TestMethod]
    public void Should_keep_the_numbers_and_the_problem_of_a_signed_out_tool()
    {
        var data = Read(new[] { Tool("cursor", 0, Line("5h", 62)) }, ("cursor", "signedOut"));

        var row = data.Summary().Rows.Single();

        Assert.AreEqual("cursor", row.Tool!.Id);
        Assert.AreEqual(62, row.Headline!.PercentLeft);
        Assert.AreEqual("signedOut", row.Problem!.Kind);
        Assert.AreEqual("signedOut", data.Stale("cursor")!.Kind);
        Assert.IsFalse(data.Alone.Any());
    }

    [TestMethod]
    public void Should_collapse_the_fine_tools_into_one_quiet_row()
    {
        var data = Read(new[]
        {
            Tool("claude", 0, Line("5h", 12, "critical")),
            Tool("codex", 0, Line("5h", 88)),
            Tool("gemini", 0, Line("1d", 64)),
        });

        var summary = data.Summary();

        Assert.AreEqual("claude", string.Join(",", summary.Rows.Select(row => row.Tool!.Id)));
        Assert.AreEqual("codex,gemini", string.Join(",", summary.Fine!.Ids));
        Assert.AreEqual(("gemini", 64), (summary.Fine.LowestId, summary.Fine.LowestPercent));
        Assert.IsFalse(summary.Fine.All);
    }

    [TestMethod]
    public void Should_be_one_quiet_row_when_everything_is_fine()
    {
        var data = Read(new[] { Tool("claude", 0, Line("5h", 62)), Tool("codex", 0, Line("5h", 88)) });

        var summary = data.Summary();

        Assert.IsEmpty(summary.Rows);
        Assert.IsTrue(summary.Fine!.All);
        Assert.AreEqual(("claude", 62), (summary.Fine.LowestId, summary.Fine.LowestPercent));
    }

    [TestMethod]
    public void Should_give_a_running_hot_tool_its_own_row()
    {
        var data = Read(new[] { Tool("claude", 0, Line("5h", 70, hot: true)), Tool("codex", 0, Line("5h", 88)) });

        Assert.AreEqual("claude", string.Join(",", data.Summary().Rows.Select(row => row.Tool!.Id)));
    }

    [TestMethod]
    public void Should_give_a_tool_without_numbers_a_row_of_its_own()
    {
        var data = Read(new[] { Tool("codex", 0, Line("5h", 88)) }, ("copilot", "failed"));

        var row = data.Summary().Rows.Single();

        Assert.IsNull(row.Tool);
        Assert.AreEqual(("copilot", "failed"), (row.Problem!.Id, row.Problem.Kind));
    }

    [TestMethod]
    public void Should_take_the_headline_and_the_others_from_the_reading()
    {
        var data = Read(new[] { Tool("omp", 2, Line("5h", 20, "warning"), Line("7d", 10, "critical"), Line("Kimi 7d", 31, "warning"), Line("GLM 5h", 90)) });

        var row = data.Summary().Rows.Single();

        Assert.AreEqual("Kimi 7d", row.Headline!.Window);
        Assert.AreEqual((3, 2), (row.Tool!.OthersCount, row.Tool.OthersAttention));
    }

    [TestMethod]
    public void Should_say_how_many_other_limits_there_are_and_how_many_are_low()
    {
        Assert.AreEqual("+12", HudText.Others(12, 0));
        Assert.AreEqual("+2 low", HudText.Others(12, 2));
        Assert.AreEqual("", HudText.Others(0, 0));
    }

    [TestMethod]
    public void Should_read_when_a_running_hot_limit_runs_out_from_the_reading()
    {
        var hot = Line("5h", 40, "warning", hot: true);
        hot["runsOutAt"] = Now.AddMinutes(95).ToUnixTimeSeconds();
        var data = Read(new[] { Tool("claude", 0, hot), Tool("codex", 0, Line("5h", 88)) });

        Assert.AreEqual(Now.AddMinutes(95), data.Summary().Rows.Single().Headline!.RunsOutAt);
        Assert.IsNull(data.Tools[1].Lines[0].RunsOutAt);
    }

    [TestMethod]
    public void Should_say_a_time_ahead_as_a_clock_time_within_a_day()
    {
        var culture = CultureInfo.GetCultureInfo("en-GB");
        Assert.AreEqual("13:35", HudText.When(Now.AddMinutes(95), Now, culture));
        Assert.AreEqual("Thu 14:00", HudText.When(Now.AddDays(2).AddHours(2), Now, culture));
    }
}
