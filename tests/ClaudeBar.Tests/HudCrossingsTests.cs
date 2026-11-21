using ClaudeBar;

namespace ClaudeBar.Tests;

/// When the HUD notifies (docs/plans/2026-10-13-hud.md, Task 11): once on a
/// crossing into critical, once at 0, once when it's back, never twice.
[TestClass]
public sealed class HudCrossingsTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 13, 12, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset Reset = Now.AddHours(2);

    /// A limit at `percent` left, with the status ClaudeBar gives it under
    /// the absolute policy: under 50% warning, under 20% critical, 0 depleted.
    private static LineNow Line(int percent, DateTimeOffset? resetsAt = null) => new("claude/5h",
        percent <= 0 ? "depleted" : percent < 20 ? "critical" : percent < 50 ? "warning" : "healthy", resetsAt ?? Reset);

    /// The crossings each reading notifies, one reading after another, from a first reading at `first`.
    private static List<string> Notified(int first, params LineNow[] readings) => Notified(Line(first), readings);

    /// The same from any first reading, every reading taken at `Now`.
    private static List<string> Notified(LineNow first, params LineNow[] readings) =>
        NotifiedAt(first, readings.Select(reading => (reading, Now)).ToArray());

    /// The same, each reading taken at its own time.
    private static List<string> NotifiedAt(LineNow first, params (LineNow Line, DateTimeOffset At)[] readings)
    {
        var (_, kept) = HudCrossings.Next(new Dictionary<string, KeptLine>(), new[] { first }, Now);
        var notified = new List<string>();
        foreach (var (reading, at) in readings)
        {
            var (notify, next) = HudCrossings.Next(kept, new[] { reading }, at);
            notified.AddRange(notify.Select(n => n.Crossing.ToString()));
            kept = next;
        }
        return notified;
    }

    /// A limit with a status as ClaudeBar gives it under any policy, and the reset it reports, if any.
    private static LineNow Status(string status, DateTimeOffset? resetsAt) => new("claude/5h", status, resetsAt);

    [TestMethod]
    public void Should_notify_when_a_limit_crosses_20_percent() =>
        CollectionAssert.AreEqual(new[] { "Low" }, Notified(25, Line(15)));

    [TestMethod]
    public void Should_not_notify_a_limit_already_under_20_percent() =>
        CollectionAssert.AreEqual(Array.Empty<string>(), Notified(15, Line(12)));

    [TestMethod]
    public void Should_notify_when_a_limit_reaches_0() =>
        CollectionAssert.AreEqual(new[] { "Out" }, Notified(12, Line(0)));

    [TestMethod]
    public void Should_notify_when_a_limit_at_0_is_back() =>
        CollectionAssert.AreEqual(new[] { "Back" }, Notified(0, Line(100, Now.AddHours(5))));

    [TestMethod]
    public void Should_notify_the_same_reading_once() =>
        CollectionAssert.AreEqual(new[] { "Low" }, Notified(25, Line(15), Line(15)));

    [TestMethod]
    public void Should_notify_a_limit_that_goes_back_over_20_and_under_again_once_in_its_window() =>
        CollectionAssert.AreEqual(new[] { "Low" }, Notified(25, Line(15), Line(22), Line(18)));

    [TestMethod]
    public void Should_notify_again_in_the_next_window() =>
        CollectionAssert.AreEqual(new[] { "Low", "Low" }, Notified(25, Line(15), Line(80, Now.AddHours(5)), Line(15, Now.AddHours(5))));

    [TestMethod]
    public void Should_not_notify_a_limit_seen_for_the_first_time() =>
        CollectionAssert.AreEqual(Array.Empty<string>(), Notified(0));

    // Under pace-aware, critical follows the time left until it runs out, so a pause and a resume
    // flip a limit between warning and critical: it is told once per window, as the Mac's status
    // alerts tell it (ClaudeBar #710, #711).

    [TestMethod]
    public void Should_not_notify_again_when_a_limit_told_before_it_had_a_reset_reports_its_first() =>
        CollectionAssert.AreEqual(new[] { "Low" }, Notified(Status("healthy", null),
            Status("critical", null), Status("warning", Reset), Status("critical", Reset)));

    [TestMethod]
    public void Should_not_start_a_window_at_a_reset_already_past() =>
        CollectionAssert.AreEqual(new[] { "Low" }, Notified(Status("healthy", null),
            Status("critical", null), Status("warning", Now.AddHours(-1)), Status("critical", Now.AddHours(-1))));

    [TestMethod]
    public void Should_notify_a_limit_with_no_reset_again_once_it_has_read_healthy() =>
        CollectionAssert.AreEqual(new[] { "Low", "Low" }, Notified(Status("healthy", null),
            Status("critical", null), Status("warning", null), Status("critical", null), Status("healthy", null), Status("critical", null)));

    [TestMethod]
    public void Should_start_a_new_window_once_its_reset_has_passed_though_the_limit_still_reports_it() =>
        CollectionAssert.AreEqual(new[] { "Low", "Low" }, NotifiedAt(Status("warning", Reset),
            (Status("critical", Reset), Now), (Status("warning", Reset), Reset.AddMinutes(1)), (Status("critical", Reset), Reset.AddMinutes(2))));

    [TestMethod]
    public void Should_keep_quiet_until_the_reset_once_asked()
    {
        var (_, kept) = HudCrossings.Next(new Dictionary<string, KeptLine>(), new[] { Line(25) }, Now);
        kept["claude/5h"] = kept["claude/5h"] with { QuietUntil = Reset };

        var (notify, _) = HudCrossings.Next(kept, new[] { Line(15) }, Now);

        Assert.IsEmpty(notify);
    }
}
