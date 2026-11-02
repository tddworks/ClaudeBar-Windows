namespace ClaudeBar;

/// The window the person was working in: the last foreground window that
/// isn't ClaudeBar's. After a click on the HUD, which activates it (measured,
/// research.md), `GiveBack` returns the foreground there. Windows allows it:
/// ClaudeBar is then the foreground process, and received the last input.
internal sealed class ForegroundTracker : IDisposable
{
    private readonly Win32.WinEventProc _proc;
    private readonly IntPtr _hook;
    private readonly uint _ownProcess = (uint)Environment.ProcessId;
    private IntPtr _last;
    private long? _gaveBack;

    /// The HUD's window: in front just after a give-back, it gives back again.
    internal IntPtr Hud;

    internal ForegroundTracker()
    {
        _proc = (_, _, window, _, _, _, _) => Remember(window);
        _hook = Win32.SetWinEventHook(Win32.EVENT_SYSTEM_FOREGROUND, Win32.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _proc, 0, 0, Win32.WINEVENT_OUTOFCONTEXT);
        Remember(Win32.GetForegroundWindow());
    }

    private void Remember(IntPtr window)
    {
        if (window == IntPtr.Zero) return;
        Win32.GetWindowThreadProcessId(window, out var process);
        if (process != _ownProcess) _last = window;
        // UI Automation's Invoke can run a button's action before it activates the
        // HUD (2 of 120 presses, check-hud): the HUD in front within a second of
        // giving back is that same press, so the foreground goes back again, once.
        // In front may be the HUD or its input site (InputSiteWindowClass, measured).
        else if (IsHud(window) && _gaveBack is { } at && Environment.TickCount64 - at < 1000)
        {
            _gaveBack = null;
            Return();
        }
    }

    private bool IsHud(IntPtr window) =>
        window == Hud || Win32.GetAncestor(window, Win32.GA_ROOT) == Hud || Win32.GetAncestor(window, Win32.GA_ROOTOWNER) == Hud;

    /// Returns the foreground to the person's window, if there is one and it
    /// hasn't closed since.
    internal void GiveBack()
    {
        _gaveBack = Environment.TickCount64;
        Return();
    }

    /// The HUD in front on purpose (its menu, a press on it): kept there.
    internal void Keep() => _gaveBack = null;

    private void Return()
    {
        if (_last != IntPtr.Zero && Win32.IsWindow(_last)) Win32.SetForegroundWindow(_last);
    }

    public void Dispose() => Win32.UnhookWinEvent(_hook);
}
