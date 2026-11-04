using System.Diagnostics;
using ClaudeBar;

namespace ClaudeBar.Tests;

/// Before *Update* quits for Velopack (docs/plans/2026-11-03-wsl-design.md,
/// An update): every distro's mutex, held until the app exits, or released
/// when the update fails. Each test's distro has a GUID in its name, so it
/// never meets a running app's mutex.
[TestClass]
public sealed class WslHoldTests
{
    [TestMethod]
    public void Should_name_a_distro_s_mutex_as_the_Swift_side_does()
    {
        Assert.AreEqual(@"Local\ClaudeBar.wsl.Ubuntu-26.04", WslHold.MutexName("Ubuntu-26.04"));
    }

    [TestMethod]
    public async Task Should_hold_each_distro_s_mutex_once_taken()
    {
        var distro = Distro();

        using var lease = await WslHold.TakeAll(new[] { distro }, TimeSpan.FromSeconds(1)).WaitAsync(TimeSpan.FromSeconds(5));

        Assert.IsFalse(await Free(distro));
        CollectionAssert.AreEqual(new[] { distro }, lease.Held.ToList());
    }

    [TestMethod]
    public async Task Should_keep_holding_every_distro_after_a_collection()
    {
        var (first, second) = (Distro(), Distro());
        using var lease = await WslHold.TakeAll(new[] { first, second }, TimeSpan.FromSeconds(1)).WaitAsync(TimeSpan.FromSeconds(5));

        for (var round = 0; round < 3; round++)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
        }

        Assert.IsFalse(await Free(first));
        Assert.IsFalse(await Free(second));
    }

    [TestMethod]
    public async Task Should_free_every_distro_once_released()
    {
        var (first, second) = (Distro(), Distro());
        var lease = await WslHold.TakeAll(new[] { first, second }, TimeSpan.FromSeconds(1)).WaitAsync(TimeSpan.FromSeconds(5));

        lease.Dispose();
        lease.Dispose();

        Assert.IsTrue(await Free(first));
        Assert.IsTrue(await Free(second));
    }

    [TestMethod]
    public async Task Should_free_every_distro_when_the_install_fails()
    {
        var distro = Distro();

        await Assert.ThrowsExactlyAsync<InvalidOperationException>(() =>
            WslHold.Install(new[] { distro }, TimeSpan.FromSeconds(1), () => throw new InvalidOperationException("Update.exe is missing")));

        Assert.IsTrue(await Free(distro));
    }

    [TestMethod]
    public async Task Should_hold_every_distro_once_the_install_is_set()
    {
        var distro = Distro();
        var installed = false;

        using var lease = await WslHold.Install(new[] { distro }, TimeSpan.FromSeconds(1), () => installed = true);

        Assert.IsTrue(installed);
        Assert.IsFalse(await Free(distro));
    }

    [TestMethod]
    public async Task Should_wait_for_a_probe_that_holds_the_mutex()
    {
        var distro = Distro();
        var (held, released) = Hold(distro, TimeSpan.FromMilliseconds(300));
        await held.Task;
        var clock = Stopwatch.StartNew();

        using var lease = await WslHold.TakeAll(new[] { distro }, TimeSpan.FromSeconds(5)).WaitAsync(TimeSpan.FromSeconds(10));

        Assert.IsTrue(released.Task.IsCompleted, "taken before the probe let go");
        Assert.IsGreaterThanOrEqualTo(200, clock.ElapsedMilliseconds);
    }

    [TestMethod]
    public async Task Should_give_up_waiting_at_the_timeout()
    {
        var distro = Distro();
        var (held, released) = Hold(distro, TimeSpan.FromSeconds(10));
        await held.Task;
        var clock = Stopwatch.StartNew();

        var lease = await WslHold.TakeAll(new[] { distro }, TimeSpan.FromMilliseconds(500)).WaitAsync(TimeSpan.FromSeconds(5));

        Assert.IsFalse(released.Task.IsCompleted);
        Assert.IsGreaterThanOrEqualTo(400, clock.ElapsedMilliseconds);
        Assert.IsLessThan(3000, clock.ElapsedMilliseconds);
        Assert.IsEmpty(lease.Held);
        // Releasing a mutex it never took would throw ApplicationException here.
        lease.Dispose();
    }

    private static string Distro() => $"Test-{Guid.NewGuid():N}";

    /// Whether a probe could take the distro's mutex now, on a thread of its own; it lets go at once.
    private static Task<bool> Free(string distro) => OnAnotherThread(() =>
    {
        using var mutex = new Mutex(false, WslHold.MutexName(distro));
        bool taken;
        try { taken = mutex.WaitOne(TimeSpan.FromMilliseconds(100)); }
        catch (AbandonedMutexException) { taken = true; }
        if (taken) mutex.ReleaseMutex();
        return taken;
    });

    /// A probe's run: the distro's mutex taken on a thread of its own, let go after `duration`.
    private static (TaskCompletionSource Held, TaskCompletionSource Released) Hold(string distro, TimeSpan duration)
    {
        var held = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var released = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        new Thread(() =>
        {
            using var mutex = new Mutex(false, WslHold.MutexName(distro));
            mutex.WaitOne();
            held.SetResult();
            Thread.Sleep(duration);
            released.SetResult();
            mutex.ReleaseMutex();
        }) { IsBackground = true }.Start();
        return (held, released);
    }

    private static Task<T> OnAnotherThread<T>(Func<T> work)
    {
        var result = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        new Thread(() => result.SetResult(work())) { IsBackground = true }.Start();
        return result.Task;
    }
}
