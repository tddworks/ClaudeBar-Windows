using System.Diagnostics;

namespace ClaudeBar;

/// The hourly upload: a Task Scheduler task that runs claudebar-upload.exe,
/// beside this app, every hour while the person is signed in. Made without a
/// password, so it runs only then, with the person's own token: it can reach
/// the network and Credential Manager, which a task run while signed out can't.
internal static class Uploads
{
    private const string TaskName = "ClaudeBar Leaderboard upload";

    private static string Uploader => Path.Combine(AppContext.BaseDirectory, "claudebar-upload.exe");

    /// Whether the task should exist, as last asked; each run acts on this, so
    /// the last ask wins even when an earlier one finishes after it.
    private static volatile bool _wanted;
    /// Whether this launch has made the task, pointing at its own uploader. A
    /// copy unzipped to another folder (an update) takes the task over from the
    /// old one the first time it runs, rather than leave it on a deleted path.
    private static volatile bool _madeHere;
    private static readonly SemaphoreSlim Gate = new(1, 1);

    /// Each runs `schtasks.exe` on a worker thread, one at a time: it can take
    /// a while, and the window mustn't wait.
    internal static Task<bool> EnsureScheduledAsync() => Apply(wanted: true, create: !_madeHere);

    /// Made again even if it exists, as on joining.
    internal static Task<bool> ScheduleAsync() => Apply(wanted: true, create: true);

    internal static Task<bool> UnscheduleAsync() => Apply(wanted: false, create: false);

    private static async Task<bool> Apply(bool wanted, bool create)
    {
        _wanted = wanted;
        await Gate.WaitAsync();
        try
        {
            return await Task.Run(() => _wanted
                ? (!create && IsScheduled) || Schedule()
                : !IsScheduled || Run("/Delete", "/F", "/TN", TaskName) == 0);
        }
        finally { Gate.Release(); }
    }

    private static bool IsScheduled => Run("/Query", "/TN", TaskName) == 0;

    private static bool Schedule() =>
        _madeHere = Run("/Create", "/F", "/SC", "HOURLY", "/TN", TaskName, "/TR", $"\"{Uploader}\"") == 0;

    private static int Run(params string[] arguments)
    {
        var start = new ProcessStartInfo("schtasks.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        process.StandardOutput.ReadToEnd();
        process.StandardError.ReadToEnd();
        process.WaitForExit();
        return process.ExitCode;
    }
}
