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

    internal static bool IsScheduled => Run("/Query", "/TN", TaskName) == 0;

    internal static bool Schedule() =>
        Run("/Create", "/F", "/SC", "HOURLY", "/TN", TaskName, "/TR", $"\"{Uploader}\"") == 0;

    internal static bool Unschedule() => !IsScheduled || Run("/Delete", "/F", "/TN", TaskName) == 0;

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
