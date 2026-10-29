using ClaudeBar;

namespace ClaudeBar.Tests;

/// Where the HUD sits and when it hides (docs/plans/2026-10-13-hud-design.md).
/// Physical pixels: a 3840 × 2160 screen at 150% with a 72 px taskbar.
[TestClass]
public sealed class HudGeometryTests
{
    private static readonly Box Screen = new(0, 0, 3840, 2160);
    private static readonly Box Work = new(0, 0, 3840, 2088);

    // The corner by name: a public test method can't take the app's internal enum.
    [TestMethod]
    [DataRow(100, 100, "TopLeft")]
    [DataRow(3000, 100, "TopRight")]
    [DataRow(100, 1500, "BottomLeft")]
    [DataRow(3000, 1500, "BottomRight")]
    public void Should_snap_to_the_corner_nearest_where_the_drag_ended(int x, int y, string expected)
    {
        Assert.AreEqual(Enum.Parse<Corner>(expected), HudGeometry.Nearest(new Box(x, y, 480, 600), Work));
    }

    [TestMethod]
    public void Should_sit_the_margin_in_from_the_work_area_so_it_clears_the_taskbar()
    {
        Assert.AreEqual(new Box(3342, 1470, 480, 600), HudGeometry.Place(Corner.BottomRight, 480, 600, Work, 18));
    }

    [TestMethod]
    public void Should_place_on_its_own_screen_when_that_screen_is_not_at_the_origin()
    {
        var second = new Box(3840, 0, 2560, 1392);
        Assert.AreEqual(new Box(3858, 18, 480, 600), HudGeometry.Place(Corner.TopLeft, 480, 600, second, 18));
    }

    [TestMethod]
    public void Should_never_be_taller_than_the_work_area_less_its_margins()
    {
        Assert.AreEqual(2088 - 36, HudGeometry.Place(Corner.BottomRight, 480, 3000, Work, 18).Height);
    }

    [TestMethod]
    public void Should_hide_for_a_window_exactly_covering_the_HUD_s_screen()
    {
        // FullScreenPresenter and borderless full screen both measured exactly the screen (research.md).
        Assert.IsTrue(HudGeometry.ShouldHide(Screen, foregroundIsDesktop: false, hudScreen: Screen, presentation: false));
    }

    [TestMethod]
    public void Should_stay_for_a_full_screen_window_on_another_screen()
    {
        Assert.IsFalse(HudGeometry.ShouldHide(new Box(3840, 0, 2560, 1440), false, Screen, false));
    }

    [TestMethod]
    public void Should_stay_for_a_maximized_window_whose_frame_runs_past_the_screen()
    {
        // With the taskbar set to hide, a maximized window spills 8 px past each edge; it isn't full screen.
        Assert.IsFalse(HudGeometry.ShouldHide(new Box(-8, -8, 3856, 2176), false, Screen, false));
    }

    [TestMethod]
    public void Should_stay_when_the_desktop_itself_is_in_front()
    {
        Assert.IsFalse(HudGeometry.ShouldHide(Screen, foregroundIsDesktop: true, hudScreen: Screen, presentation: false));
    }

    [TestMethod]
    public void Should_hide_during_a_presentation_whatever_is_in_front()
    {
        Assert.IsTrue(HudGeometry.ShouldHide(new Box(10, 10, 800, 600), false, Screen, presentation: true));
    }
}
