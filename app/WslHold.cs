namespace ClaudeBar;

/// Before *Update* quits for Velopack (docs/plans/2026-11-03-wsl-design.md,
/// An update): every distro's mutex, which waits for a probe the app or the
/// uploader runs, held on a thread of its own until the app exits. Windows
/// can't rename a folder a Linux program runs from, so an update during a
/// probe would fail. Best effort: an hourly upload can still start one
/// before Velopack renames.
internal static class WslHold
{
    /// The same name the Swift side takes for a run (`WslCommand`).
    internal static string MutexName(string distro) => $@"Local\ClaudeBar.wsl.{distro}";

    /// Takes each distro's mutex in turn, waiting `timeout` in all; done when
    /// each is taken or the time is up. A mutex is owned by the thread that
    /// took it, so one thread takes them all and keeps them.
    internal static Task TakeAll(IReadOnlyList<string> distros, TimeSpan timeout)
    {
        var taken = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var until = DateTime.UtcNow + timeout;
            foreach (var distro in distros)
            {
                var mutex = new Mutex(false, MutexName(distro));
                try { mutex.WaitOne(Max(until - DateTime.UtcNow, TimeSpan.Zero)); }
                catch (AbandonedMutexException) { }
            }
            taken.SetResult();
            Thread.Sleep(Timeout.Infinite);   // held until the process exits, which releases them
        }) { IsBackground = true, Name = "WSL update hold" };
        thread.Start();
        return taken.Task;
    }

    private static TimeSpan Max(TimeSpan a, TimeSpan b) => a > b ? a : b;
}
