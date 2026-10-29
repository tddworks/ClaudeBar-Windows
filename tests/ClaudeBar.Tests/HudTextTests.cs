using System.Globalization;
using System.Text.Json.Nodes;
using ClaudeBar;

namespace ClaudeBar.Tests;

/// The HUD's words for time and for each limit (docs/plans/2026-10-13-hud-design.md).
[TestClass]
public sealed class HudTextTests
{
    private static readonly DateTimeOffset Now = new(new DateTime(2026, 10, 13, 12, 16, 0, DateTimeKind.Local));

    [TestMethod]
    public void Should_count_a_part_minute_as_a_minute()
    {
        Assert.AreEqual("1m", HudText.Reset(62, Now.AddSeconds(59), Now, CultureInfo.InvariantCulture));
    }

    [TestMethod]
    public void Should_give_hours_and_minutes_under_a_day()
    {
        Assert.AreEqual("2h 14m", HudText.Reset(62, Now.AddHours(2).AddMinutes(14), Now, CultureInfo.InvariantCulture));
    }

    [TestMethod]
    public void Should_give_days_and_hours_over_a_day()
    {
        Assert.AreEqual("3d 6h", HudText.Reset(71, Now.AddDays(3).AddHours(6), Now, CultureInfo.InvariantCulture));
    }

    // The PC's clock format: 24-hour in one culture, AM/PM in another (ICU may
    // put a narrow no-break space before PM, so that one is matched by parts).
    [TestMethod]
    public void Should_say_when_a_limit_at_0_is_back_as_a_clock_time()
    {
        var back = new DateTimeOffset(new DateTime(2026, 10, 13, 14, 30, 0, DateTimeKind.Local));
        Assert.AreEqual("back 14:30", HudText.Reset(0, back, Now, CultureInfo.GetCultureInfo("en-GB")));
        var american = HudText.Reset(0, back, Now, CultureInfo.GetCultureInfo("en-US"));
        StringAssert.StartsWith(american, "back 2:30");
        StringAssert.EndsWith(american, "PM");
    }

    [TestMethod]
    public void Should_read_a_limit_as_one_sentence_for_UI_Automation()
    {
        var line = new HudData.Line("5h", 62, Now.AddHours(2).AddMinutes(14), 5 * 3600, "healthy", false, 44.7, true);
        Assert.AreEqual("Claude, 5-hour limit: 62% left, resets in 2 hours 14 minutes", HudText.Sentence("Claude", line, Now, CultureInfo.InvariantCulture));
    }

    [TestMethod]
    public void Should_read_the_check_s_sample_as_the_C_interface_sends_it()
    {
        var reply = (JsonObject)JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "hud-check.json")))!;
        var data = HudData.Parse(reply)!;

        Assert.AreEqual("claude,codex,gemini", string.Join(",", data.Tools.Select(tool => tool.Id)));
        Assert.AreEqual("5h,7d", string.Join(",", data.Tools[0].Lines.Select(line => line.Window)));
        Assert.AreEqual(DateTimeOffset.FromUnixTimeSeconds(1_791_900_000 + 2 * 3600 + 14 * 60), data.Tools[0].Lines[0].ResetsAt);
        Assert.AreEqual("depleted", data.Worst);
        Assert.AreEqual("signedOut", data.Problems[1].Kind);
        Assert.AreEqual("Codex", data.LookOf("codex.work").Name);
    }
}
