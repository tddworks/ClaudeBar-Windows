namespace ClaudeBar;

/// Before *Update* quits for Velopack (docs/plans/2026-11-03-wsl-design.md,
/// An update): every distro's mutex, which waits for a probe the app or the
/// uploader runs, held on a thread of its own until the app exits, or until
/// the update fails and the lease is released. Windows can't rename a folder
/// a Linux program runs from, so an update during a probe would fail. Best
/// effort: an hourly upload can still start one before Velopack renames.
internal static class WslHold
{
    /// The same name the Swift side takes for a run (`WslCommand`).
    internal static string MutexName(string distro) => $@"Local\ClaudeBar.wsl.{distro}";

    /// Takes each distro's mutex in turn, waiting `timeout` in all; done when
    /// each is taken or the time is up. A mutex is owned by the thread that
    /// took it, so one thread takes them all and keeps them until the lease
    /// is released, or the process exits, which releases them too.
    internal static Task<Lease> TakeAll(IReadOnlyList<string> distros, TimeSpan timeout)
    {
        var taken = new TaskCompletionSource<Lease>(TaskCreationOptions.RunContinuationsAsynchronously);
        var lease = new Lease();
        var thread = new Thread(() => lease.Run(distros, timeout, taken)) { IsBackground = true, Name = "WSL update hold" };
        lease.Thread = thread;
        thread.Start();
        return taken.Task;
    }

    /// The update's last step before it quits: holds every distro, then
    /// `install` (Velopack's `InstallWhenQuit`). When that throws, every
    /// distro is free again before the exception goes on, so later probes
    /// don't wait on an update that isn't coming.
    internal static async Task<Lease> Install(IReadOnlyList<string> distros, TimeSpan timeout, Action install)
    {
        var lease = await TakeAll(distros, timeout);
        try
        {
            install();
            return lease;
        }
        catch
        {
            lease.Dispose();
            throw;
        }
    }

    /// The distros' mutexes, kept alive while held: a `Mutex` the GC
    /// finalizes closes its handle, and with the last handle gone the named
    /// mutex is gone, and a probe would make a fresh one. Releasing it, once
    /// or more, lets go of each one it took and ends its thread.
    internal sealed class Lease : IDisposable
    {
        private readonly List<Mutex> _mutexes = new();
        private readonly List<string> _held = new();
        private readonly ManualResetEventSlim _release = new();
        private Exception? _failure;

        internal Thread? Thread { private get; set; }

        /// The distros whose mutex it took: not one whose wait ran out.
        internal IReadOnlyList<string> Held => _held;

        internal void Run(IReadOnlyList<string> distros, TimeSpan timeout, TaskCompletionSource<Lease> taken)
        {
            var held = new List<Mutex>();
            var until = DateTime.UtcNow + timeout;
            foreach (var distro in distros)
            {
                var mutex = new Mutex(false, MutexName(distro));
                _mutexes.Add(mutex);
                bool owned;
                try { owned = mutex.WaitOne(Max(until - DateTime.UtcNow, TimeSpan.Zero)); }
                catch (AbandonedMutexException) { owned = true; }
                if (!owned) continue;
                held.Add(mutex);
                _held.Add(distro);
            }
            taken.SetResult(this);
            _release.Wait();
            try
            {
                foreach (var mutex in held) mutex.ReleaseMutex();
            }
            catch (Exception error) { _failure = error; }
            finally
            {
                foreach (var mutex in _mutexes) mutex.Dispose();
            }
        }

        /// Lets go of every mutex it took, on its own thread, and waits for that.
        public void Dispose()
        {
            if (_release.IsSet) return;
            _release.Set();
            Thread?.Join();
            if (_failure is { } failure) throw failure;
        }
    }

    private static TimeSpan Max(TimeSpan a, TimeSpan b) => a > b ? a : b;
}
