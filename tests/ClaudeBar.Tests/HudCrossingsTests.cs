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
    private static List<string> Notified(int first, params LineNow[] readings)
    {
        var (_, kept) = HudCrossings.Next(new Dictionary<string, KeptLine>(), new[] { Line(first) }, Now);
        var notified = new List<string>();
        foreach (var reading in readings)
        {
            var (notify, next) = HudCrossings.Next(kept, new[] { reading }, Now);
            notified.AddRange(notify.Select(n => n.Crossing.ToString()));
            kept = next;
        }
        return notified;
    }

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

    [TestMethod]
    public void Should_keep_quiet_until_the_reset_once_asked()
    {
        var (_, kept) = HudCrossings.Next(new Dictionary<string, KeptLine>(), new[] { Line(25) }, Now);
        kept["claude/5h"] = kept["claude/5h"] with { QuietUntil = Reset };

        var (notify, _) = HudCrossings.Next(kept, new[] { Line(15) }, Now);

        Assert.IsEmpty(notify);
    }
}
