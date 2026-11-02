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
    private static readonly SemaphoreSlim Gate = new(1, 1);

    /// Each runs `schtasks.exe` on a worker thread, one at a time: it can take
    /// a while, and the window mustn't wait.
    /// A task that runs another copy's uploader (a zip install Setup replaced,
    /// an older folder) is pointed at this one's.
    internal static Task<bool> EnsureScheduledAsync() => Apply(wanted: true, create: false);

    /// Made again even if it exists, as on joining.
    internal static Task<bool> ScheduleAsync() => Apply(wanted: true, create: true);

    internal static Task<bool> UnscheduleAsync() => Apply(wanted: false, create: false);

    /// For Velopack's install and update hooks, which show no UI and must end
    /// within 15 seconds: points an existing task at this copy's uploader. It
    /// never makes one: only joining does.
    internal static void FollowThisCopy()
    {
        if (IsScheduled && !PointsHere) Schedule();
    }

    /// For the uninstall hook: the task would run an uploader that's gone.
    internal static void Remove()
    {
        if (IsScheduled) Run("/Delete", "/F", "/TN", TaskName);
    }

    private static async Task<bool> Apply(bool wanted, bool create)
    {
        _wanted = wanted;
        await Gate.WaitAsync();
        try
        {
            return await Task.Run(() => _wanted
                ? (!create && PointsHere) || Schedule()
                : !IsScheduled || Run("/Delete", "/F", "/TN", TaskName).Code == 0);
        }
        finally { Gate.Release(); }
    }

    private static bool IsScheduled => Run("/Query", "/TN", TaskName).Code == 0;

    /// Whether the task exists and runs this copy's uploader.
    private static bool PointsHere =>
        Run("/Query", "/TN", TaskName, "/XML") is { Code: 0 } query && UploadTask.PointsAt(UploadTask.Command(query.Output), Uploader);

    private static bool Schedule() =>
        Run("/Create", "/F", "/SC", "HOURLY", "/TN", TaskName, "/TR", $"\"{Uploader}\"").Code == 0;

    private static (int Code, string Output) Run(params string[] arguments)
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
        var error = process.StandardError.ReadToEndAsync();
        var output = process.StandardOutput.ReadToEnd();
        error.Wait();
        process.WaitForExit();
        return (process.ExitCode, output);
    }
}
