using System.Text.Json.Nodes;
using ClaudeBar;

namespace ClaudeBar.Tests;

/// An aggregator's groups as their own tools (docs/plans/2026-10-13-hud-design.md,
/// Groups): titles that keep their words, keys that survive the split, and
/// tools hidden before it stay hidden.
[TestClass]
public sealed class HudGroupsTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 13, 12, 0, 0, TimeSpan.Zero);

    // MARK: - Titles

    [TestMethod]
    public void Should_name_a_window_that_says_only_its_length_by_its_length()
    {
        Assert.AreEqual("7-day limit", HudText.LimitName("7d", 7 * 86_400));
        Assert.AreEqual("5-hour limit", HudText.LimitName("5h", null));
        Assert.AreEqual("30-day limit", HudText.LimitName("month", 30 * 86_400));
        // Codex's first window can be the weekly one: the stated length wins over the name.
        Assert.AreEqual("7-day limit", HudText.LimitName("5h", 7 * 86_400));
    }

    [TestMethod]
    public void Should_keep_every_word_a_window_says_beyond_its_length()
    {
        Assert.AreEqual("Codex 7d limit", HudText.LimitName("Codex 7d", 7 * 86_400));
        Assert.AreEqual("Spark 7d limit", HudText.LimitName("Spark 7d", 7 * 86_400));
        Assert.AreEqual("Opus limit", HudText.LimitName("Opus", 7 * 86_400));
    }

    [TestMethod]
    public void Should_read_a_group_line_by_its_length_inside_its_group()
    {
        var data = Read(Tool("omp/Codex", "Codex", "omp", Line("7d", "time:Codex 7d", 12), Line("Spark 7d", "time:Codex Spark 7d", 80)));

        var tool = data.Tools.Single();
        Assert.AreEqual("7-day limit", HudText.LimitName(tool.Lines[0].Window, tool.Lines[0].WindowSeconds));
        Assert.AreEqual("Codex, 7-day limit: 12% left, resets in 2 hours", HudText.Sentence(data.LookOf(tool.Id).Name, tool.Lines[0], Now, System.Globalization.CultureInfo.InvariantCulture));
    }

    // MARK: - The reading

    [TestMethod]
    public void Should_read_each_group_as_a_tool_with_its_aggregator()
    {
        var data = Read(Tool("omp/Claude", "Claude", "omp", Line("5h", "time:Claude 5h", 70)), Tool("omp/Codex", "Codex", "omp", Line("7d", "time:Codex 7d", 12)));

        Assert.AreEqual("omp/Claude,omp/Codex", string.Join(",", data.Tools.Select(tool => tool.Id)));
        Assert.AreEqual("Claude,Codex", string.Join(",", data.Tools.Select(tool => tool.Group)));
        Assert.AreEqual("omp,omp", string.Join(",", data.Tools.Select(tool => tool.Via)));
        Assert.AreEqual("Codex · via Oh My Pi", data.Header(data.Tools[1]));
        Assert.AreEqual("Codex", data.LookOf("omp/Codex").Name);
        Assert.AreEqual("#1C9E93", data.LookOf("omp/Codex").Light);
    }

    [TestMethod]
    public void Should_head_a_tool_of_its_own_by_its_name_alone()
    {
        var data = Read(Tool("claude", null, null, Line("5h", "session", 62)));

        Assert.IsNull(data.Tools[0].Via);
        Assert.AreEqual("Claude", data.Header(data.Tools[0]));
    }

    [TestMethod]
    public void Should_show_each_group_that_needs_you_as_its_own_row()
    {
        var data = Read(Tool("omp/Claude", "Claude", "omp", Line("5h", "time:Claude 5h", 70)),
                        Tool("omp/Codex", "Codex", "omp", Line("7d", "time:Codex 7d", 12, "critical")));

        var summary = data.Summary();

        Assert.AreEqual("omp/Codex", string.Join(",", summary.Rows.Select(row => row.Tool!.Id)));
        Assert.AreEqual("omp/Claude", string.Join(",", summary.Fine!.Ids));
    }

    // MARK: - Keys

    [TestMethod]
    public void Should_key_a_line_by_its_login_and_ClaudeBar_s_quota_key_never_by_its_title()
    {
        var data = Read(Tool("claude", null, null, Line("5h", "session", 62)),
                        Tool("omp/Claude · alice", "Claude · alice", "omp", Line("5h", "time:Claude 5h · alice", 40)),
                        Tool("omp/Claude · bob", "Claude · bob", "omp", Line("5h", "time:Claude 5h · bob", 70)));

        var keys = data.Tools.Select(tool => HudData.Key(tool, tool.Lines[0])).ToList();

        CollectionAssert.AreEqual(new[] { "claude/session", "omp/time:Claude 5h · alice", "omp/time:Claude 5h · bob" }, keys);
    }

    [TestMethod]
    public void Should_quiet_one_account_s_limit_and_still_notify_the_other_s()
    {
        LineNow Alice(int percent) => new("omp/time:Claude 5h · alice", Status(percent), Now.AddHours(2));
        LineNow Bob(int percent) => new("omp/time:Claude 5h · bob", Status(percent), Now.AddHours(2));
        var (_, kept) = HudCrossings.Next(new Dictionary<string, KeptLine>(), new[] { Alice(40), Bob(40) }, Now);

        kept = HudCrossings.Quiet(kept, "omp/time:Claude 5h · alice", Now);
        var (notify, next) = HudCrossings.Next(kept, new[] { Alice(15), Bob(15) }, Now);

        Assert.AreEqual(Now.AddHours(2), next["omp/time:Claude 5h · alice"].QuietUntil);
        Assert.IsNull(next["omp/time:Claude 5h · bob"].QuietUntil);
        CollectionAssert.AreEqual(new[] { ("omp/time:Claude 5h · bob", Crossing.Low) }, notify.ToList());
    }

    [TestMethod]
    public void Should_keep_each_account_s_limit_apart()
    {
        var (_, kept) = HudCrossings.Next(new Dictionary<string, KeptLine>(), new[]
        {
            new LineNow("omp/time:Claude 5h · alice", "critical", Now.AddHours(1)),
            new LineNow("omp/time:Claude 5h · bob", "healthy", Now.AddHours(3)),
        }, Now);

        Assert.AreEqual(("critical", Now.AddHours(1)), (kept["omp/time:Claude 5h · alice"].Status, kept["omp/time:Claude 5h · alice"].ResetsAt));
        Assert.AreEqual(("healthy", Now.AddHours(3)), (kept["omp/time:Claude 5h · bob"].Status, kept["omp/time:Claude 5h · bob"].ResetsAt));
    }

    [TestMethod]
    public void Should_let_a_key_its_login_no_longer_reports_expire()
    {
        // Keys from before the split (`omp/Kimi 7d`) and lines gone from a login that answered go;
        // a login missing from this reading keeps where it was.
        var before = new Dictionary<string, KeptLine>
        {
            ["omp/Kimi 7d"] = new("critical", Now.AddDays(2), new[] { Crossing.Low }, Now.AddDays(2)),
            ["codex/session"] = new("warning", Now.AddHours(1), Array.Empty<Crossing>()),
        };

        var (notify, kept) = HudCrossings.Next(before, new[] { new LineNow("omp/time:Kimi 7d", "critical", Now.AddDays(2)) }, Now);

        Assert.IsEmpty(notify);
        CollectionAssert.AreEquivalent(new[] { "codex/session", "omp/time:Kimi 7d" }, kept.Keys.ToList());
    }

    // MARK: - Hidden tools

    [TestMethod]
    public void Should_hide_every_group_of_an_aggregator_hidden_before_the_split()
    {
        var data = Read(Tool("claude", null, null, Line("5h", "session", 62)),
                        Tool("omp/Claude", "Claude", "omp", Line("5h", "time:Claude 5h", 70)),
                        Tool("omp/Codex", "Codex", "omp", Line("7d", "time:Codex 7d", 12)));

        var hidden = data.Hidden(new HashSet<string> { "omp" });

        CollectionAssert.AreEquivalent(new[] { "omp", "omp/Claude", "omp/Codex" }, hidden.ToList());
        Assert.AreEqual("claude", string.Join(",", data.Without(hidden).Tools.Select(tool => tool.Id)));
        CollectionAssert.AreEquivalent(new[] { "claude" }, data.Hidden(new HashSet<string> { "claude" }).ToList());
    }

    [TestMethod]
    public void Should_show_a_group_again_without_showing_the_aggregator_s_others()
    {
        var data = Read(Tool("omp/Claude", "Claude", "omp", Line("5h", "time:Claude 5h", 70)),
                        Tool("omp/Codex", "Codex", "omp", Line("7d", "time:Codex 7d", 12)));
        var hidden = data.Hidden(new HashSet<string> { "omp" });

        var shown = data.Showing(hidden, "omp/Codex");

        CollectionAssert.AreEquivalent(new[] { "omp/Claude" }, shown.ToList());
    }

    // MARK: - Helpers

    private static string Status(int percent) =>
        percent <= 0 ? "depleted" : percent < 20 ? "critical" : percent < 50 ? "warning" : "healthy";

    private static JsonObject Line(string window, string key, int percent, string status = "healthy") => new()
    {
        ["key"] = key, ["window"] = window, ["percentLeft"] = percent, ["resetsAt"] = Now.AddHours(2).ToUnixTimeSeconds(),
        ["windowSeconds"] = window.EndsWith("7d") ? 604800 : 18000, ["status"] = status, ["runningHot"] = false, ["tick"] = 40.0, ["strip"] = true,
    };

    private static JsonObject Tool(string id, string? group, string? via, params JsonObject[] lines) => new()
    {
        ["id"] = id, ["group"] = group, ["via"] = via, ["lines"] = new JsonArray(lines.Select(line => (JsonNode?)line).ToArray()),
        ["outUntil"] = null, ["runningHot"] = false, ["headline"] = 0,
        ["others"] = new JsonObject { ["count"] = lines.Length - 1, ["attention"] = 0 },
    };

    /// The reply as it crosses the C interface, with the looks the native side sends.
    private static HudData Read(params JsonObject[] tools) => HudData.Parse((JsonObject)JsonNode.Parse(new JsonObject
    {
        ["reading"] = new JsonObject { ["tools"] = new JsonArray(tools.Select(tool => (JsonNode?)tool).ToArray()), ["worst"] = "healthy" },
        ["readAt"] = Now.ToUnixTimeSeconds(),
        ["problems"] = new JsonArray(),
        ["looks"] = new JsonArray(
            Look("claude", "Claude", "#E2674A"), Look("omp", "Oh My Pi", "#299E61"),
            Look("omp/Claude", "Claude", "#E2674A"), Look("omp/Codex", "Codex", "#1C9E93")),
    }.ToJsonString())!)!;

    private static JsonNode Look(string id, string name, string light) => new JsonObject { ["id"] = id, ["name"] = name, ["light"] = light, ["dark"] = light };
}
