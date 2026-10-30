using ClaudeBar;

namespace ClaudeBar.Tests;

/// A press on the HUD: a click, or a drag once it moves past the system's
/// drag threshold (SM_CXDRAG × SM_CYDRAG, 4 px at 100%). Screen pixels.
[TestClass]
public sealed class HudDragTests
{
    private static HudDrag Pressed(int x = 1000, int y = 800) => new(new Pixel(x, y), window: new Pixel(900, 700), threshold: new Pixel(4, 4));

    [TestMethod]
    public void Should_be_a_click_when_released_where_it_went_down()
    {
        var press = Pressed();
        Assert.AreEqual(HudPress.Click, press.Release());
    }

    [TestMethod]
    [DataRow(4, 0)]
    [DataRow(0, -4)]
    [DataRow(-3, 3)]
    public void Should_stay_a_click_while_it_moves_no_further_than_the_threshold(int dx, int dy)
    {
        var press = Pressed();
        Assert.IsNull(press.Move(new Pixel(1000 + dx, 800 + dy)));
        Assert.AreEqual(HudPress.Click, press.Release());
    }

    [TestMethod]
    [DataRow(5, 0)]
    [DataRow(0, -5)]
    public void Should_become_a_drag_once_it_moves_past_the_threshold_either_way(int dx, int dy)
    {
        var press = Pressed();
        Assert.AreEqual(new Pixel(900 + dx, 700 + dy), press.Move(new Pixel(1000 + dx, 800 + dy)));
        Assert.AreEqual(HudPress.Drag, press.Release());
    }

    [TestMethod]
    public void Should_keep_the_window_under_the_pointer_where_it_was_pressed()
    {
        var press = Pressed();
        press.Move(new Pixel(1100, 800));
        Assert.AreEqual(new Pixel(500, 300), press.Move(new Pixel(600, 400)));
    }

    [TestMethod]
    public void Should_stay_a_drag_when_the_pointer_comes_back_to_where_it_went_down()
    {
        var press = Pressed();
        press.Move(new Pixel(1020, 800));
        Assert.AreEqual(new Pixel(900, 700), press.Move(new Pixel(1000, 800)));
        Assert.AreEqual(HudPress.Drag, press.Release());
    }
}
