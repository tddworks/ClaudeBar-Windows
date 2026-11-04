using System.Diagnostics;
using ClaudeBar;

namespace ClaudeBar.Tests;

/// Before *Update* quits for Velopack (docs/plans/2026-11-03-wsl-design.md,
/// An update): every distro's mutex, held until the app exits. Each test's
/// distro has a GUID in its name, so it never meets a running app's mutex.
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

        await WslHold.TakeAll(new[] { distro }, TimeSpan.FromSeconds(1)).WaitAsync(TimeSpan.FromSeconds(5));

        Assert.IsFalse(await OnAnotherThread(() => new Mutex(false, WslHold.MutexName(distro)).WaitOne(TimeSpan.FromMilliseconds(100))));
    }

    [TestMethod]
    public async Task Should_wait_for_a_probe_that_holds_the_mutex()
    {
        var distro = Distro();
        var (held, released) = Hold(distro, TimeSpan.FromMilliseconds(300));
        await held.Task;
        var clock = Stopwatch.StartNew();

        await WslHold.TakeAll(new[] { distro }, TimeSpan.FromSeconds(5)).WaitAsync(TimeSpan.FromSeconds(10));

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

        await WslHold.TakeAll(new[] { distro }, TimeSpan.FromMilliseconds(500)).WaitAsync(TimeSpan.FromSeconds(5));

        Assert.IsFalse(released.Task.IsCompleted);
        Assert.IsGreaterThanOrEqualTo(400, clock.ElapsedMilliseconds);
        Assert.IsLessThan(3000, clock.ElapsedMilliseconds);
    }

    private static string Distro() => $"Test-{Guid.NewGuid():N}";

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
