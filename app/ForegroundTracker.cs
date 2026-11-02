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

    internal ForegroundTracker()
    {
        _proc = (_, _, window, _, _, _, _) => Remember(window);
        _hook = Win32.SetWinEventHook(Win32.EVENT_SYSTEM_FOREGROUND, Win32.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _proc, 0, 0, Win32.WINEVENT_OUTOFCONTEXT);
        Remember(Win32.GetForegroundWindow());
    }

    private void Remember(IntPtr window)
    {
        Win32.GetWindowThreadProcessId(window, out var process);
        if (window != IntPtr.Zero && process != _ownProcess) _last = window;
    }

    /// Returns the foreground to the person's window, if there is one and it
    /// hasn't closed since.
    internal void GiveBack()
    {
        if (_last != IntPtr.Zero && Win32.IsWindow(_last)) Win32.SetForegroundWindow(_last);
    }

    public void Dispose() => Win32.UnhookWinEvent(_hook);
}
