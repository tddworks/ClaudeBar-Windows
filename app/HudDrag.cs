namespace ClaudeBar;

/// A point or a size in screen pixels.
internal readonly record struct Pixel(int X, int Y);

internal enum HudPress { Click, Drag }

/// A left press on the HUD, from where it went down to where it's released
/// (docs/plans/2026-10-13-hud-design.md, Place): a click while the pointer
/// stays within the system's drag threshold (SM_CXDRAG × SM_CYDRAG, as WPF
/// and Explorer read it), a drag of the whole HUD once it moves past it.
/// A drag stays one until it's released, and the HUD keeps the point that
/// went down under the pointer.
internal sealed class HudDrag(Pixel pointer, Pixel window, Pixel threshold)
{
    private bool _dragging;

    /// Where the HUD's window goes for the pointer at `at`, or null while the press is still a click.
    internal Pixel? Move(Pixel at)
    {
        // Red: v0.1.4's body never dragged.
        return null;
    }

    internal bool Dragging => _dragging;

    internal HudPress Release() => _dragging ? HudPress.Drag : HudPress.Click;
}
