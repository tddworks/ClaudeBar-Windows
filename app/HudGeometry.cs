namespace ClaudeBar;

/// A rectangle in physical pixels, as Win32 and AppWindow give them.
internal readonly record struct Box(int X, int Y, int Width, int Height)
{
    internal int Right => X + Width;
    internal int Bottom => Y + Height;
}

internal enum Corner { TopLeft, TopRight, BottomLeft, BottomRight }

/// Where the HUD sits, and when it hides (docs/plans/2026-10-13-hud-design.md).
internal static class HudGeometry
{
    /// The corner of the work area nearest the HUD's centre, where a drag ends.
    internal static Corner Nearest(Box hud, Box work)
    {
        var right = hud.X + hud.Width / 2 > work.X + work.Width / 2;
        var bottom = hud.Y + hud.Height / 2 > work.Y + work.Height / 2;
        return (right, bottom) switch
        {
            (false, false) => Corner.TopLeft,
            (true, false) => Corner.TopRight,
            (false, true) => Corner.BottomLeft,
            _ => Corner.BottomRight,
        };
    }

    /// The HUD at a corner of the work area, `margin` in from its edges, and
    /// never larger than the work area less the margins.
    internal static Box Place(Corner corner, int width, int height, Box work, int margin)
    {
        width = Math.Min(width, work.Width - 2 * margin);
        height = Math.Min(height, work.Height - 2 * margin);
        var x = corner is Corner.TopLeft or Corner.BottomLeft ? work.X + margin : work.Right - margin - width;
        var y = corner is Corner.TopLeft or Corner.TopRight ? work.Y + margin : work.Bottom - margin - height;
        return new Box(x, y, width, height);
    }

    /// The window's rectangle, as `MoveAndResize` takes it, for content
    /// `width` × `height` at `corner`, with the frame Windows draws `margin`
    /// in from the work area. A window's rectangle counts invisible resize
    /// borders the screen doesn't show (9 px left, right and below at 150%), and
    /// the frame draws a border around the content: `window` (GetWindowRect),
    /// `frame` (DWMWA_EXTENDED_FRAME_BOUNDS) and `client` are one measurement
    /// of the HUD, in screen pixels, that gives both.
    internal static Box Place(Corner corner, int width, int height, Box work, int margin, Box window, Box frame, Box client)
    {
        var visible = Place(corner, width + frame.Width - client.Width, height + frame.Height - client.Height, work, margin);
        return new Box(visible.X - (frame.X - window.X), visible.Y - (frame.Y - window.Y),
                       visible.Width + window.Width - frame.Width, visible.Height + window.Height - frame.Height);
    }

    /// Hidden while the window in front is exactly the HUD's screen (full
    /// screen, a game, a video), unless that's the desktop, and during a
    /// presentation. The shell's own busy state isn't used: it missed a
    /// full-screen window on the second screen (research.md).
    internal static bool ShouldHide(Box foreground, bool foregroundIsDesktop, Box hudScreen, bool presentation) =>
        presentation || (!foregroundIsDesktop && foreground == hudScreen);
}
