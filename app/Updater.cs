using System.Reflection;
using System.Runtime.InteropServices;
using Velopack;
using Velopack.Sources;

namespace ClaudeBar;

/// Velopack's `UpdateManager` over this repo's releases (or a local feed,
/// `UpdateFeed`): checks, downloads, and hands the install to `Update.exe`,
/// which waits for the app to quit, swaps `current` and starts the new version
/// (docs/plans/2026-11-02-updates-design.md).
internal sealed partial class Updater
{
    private readonly UpdateManager _manager;
    private UpdateInfo? _found;

    internal Updater()
    {
        var feed = UpdateFeed.Choose(Environment.GetEnvironmentVariable("CLAUDEBAR_UPDATE_FEED"));
        IUpdateSource source = feed.Local
            ? new SimpleFileSource(new DirectoryInfo(feed.Location))
            : new GithubSource(feed.Location, accessToken: null, prerelease: feed.Prereleases);
        _manager = new UpdateManager(source);
    }

    /// Installed by Setup; a zip's or `build.ps1`'s copy isn't, and can't update.
    internal bool Installed => _manager.IsInstalled;

    /// The installed package's version, else the exe's.
    internal string Version => _manager.CurrentVersion?.ToString()
        ?? Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "";

    /// The newer version the releases have, or null.
    internal async Task<string?> CheckAsync()
    {
        _found = await _manager.CheckForUpdatesAsync();
        return _found?.TargetFullRelease.Version.ToString();
    }

    /// Downloads what the last check found, a delta when there is one; `progress` is 0 to 100.
    internal Task DownloadAsync(Action<int> progress) =>
        _manager.DownloadUpdatesAsync(_found ?? throw new InvalidOperationException("No update was found."), progress);

    /// Starts `Update.exe`, which waits up to a minute for this process to end,
    /// installs the download and starts the new version. The app quits right after.
    internal void InstallWhenQuit() =>
        _manager.WaitExitThenApplyUpdates(_found?.TargetFullRelease, silent: true, restart: true);

    /// Whether the person is in a full-screen app, a game or a presentation now.
    internal static bool PersonIsBusy => SHQueryUserNotificationState(out var state) == 0 && UpdateSchedule.Busy(state);

    [LibraryImport("shell32.dll")]
    private static partial int SHQueryUserNotificationState(out int state);
}
