using System.Globalization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace ClaudeBar;

/// Updates (docs/plans/2026-11-02-updates-design.md): a check at start and
/// every 4 hours, never while the person is busy full screen; an InfoBar and
/// one notification per version found; *Update* in Settings downloads it,
/// quits, and `Update.exe` installs it and starts the new version.
public sealed partial class MainWindow
{
    private Updater? _updater;
    private UpdateStatus _update = UpdateStatus.Start("", installed: false);
    private DispatcherQueueTimer? _updateTimer;
    /// The version whose InfoBar the person closed; Settings still offers it.
    private string? _updateBarClosed;

    private void StartUpdates()
    {
        _updater = new Updater();
        _update = UpdateStatus.Start(_updater.Version, _updater.Installed);
        ShowUpdate();
        // Informational, not Success, which closes itself: the person may be looking elsewhere while it restarts.
        if (Program.UpdatedTo is { } version) Tell($"Updated to {version}.", InfoBarSeverity.Informational);
        if (!_updater.Installed) return;
        _updateTimer = DispatcherQueue.CreateTimer();
        _updateTimer.IsRepeating = false;
        _updateTimer.Tick += (_, _) => _ = ScheduledCheck();
        CheckAgainAfter(UpdateSchedule.Outcome.Started);
    }

    private void CheckAgainAfter(UpdateSchedule.Outcome outcome)
    {
        if (_updateTimer is null) return;
        _updateTimer.Interval = UpdateSchedule.After(outcome);
        _updateTimer.Start();
    }

    /// Always sets the next check, even if this one throws: the timer fires once per setting.
    private async Task ScheduledCheck()
    {
        var outcome = UpdateSchedule.Outcome.Failed;
        try
        {
            outcome = Updater.PersonIsBusy ? UpdateSchedule.Outcome.Busy
                : await CheckForUpdates() ? UpdateSchedule.Outcome.Checked : UpdateSchedule.Outcome.Failed;
        }
        catch (Exception error) { Tell(error.Message, InfoBarSeverity.Error); }
        finally { CheckAgainAfter(outcome); }
    }

    /// Checks unless a check or an update runs; answers false when the check failed.
    private async Task<bool> CheckForUpdates()
    {
        if (_updater is null || !_update.CanCheck) return true;
        _update = _update.Checking();
        ShowUpdate();
        try
        {
            var found = await _updater.CheckAsync();
            _update = _update.Checked(found, DateTimeOffset.Now);
        }
        catch (Exception error)
        {
            _update = _update.CheckFailed(error.Message);
            ShowUpdate();
            return false;
        }
        ShowUpdate();
        if (_update.Available is { } available && UpdateStatus.ShouldNotify(available, Preferences.UpdateNotified, _update.Current))
        {
            // Kept first: one that can't be kept would be notified again at every check.
            Preferences.UpdateNotified = available;
            App.Notify($"ClaudeBar {available} is available", "Update installs it and restarts ClaudeBar. Your settings and membership stay.",
                ("Update", "--update"));
        }
        return true;
    }

    /// Downloads what the check found, then quits for `Update.exe` to install it and start the new version.
    private async Task Update()
    {
        if (_updater is null || !_update.CanUpdate) return;
        _update = _update.Downloading(0);
        ShowUpdate();
        try
        {
            await _updater.DownloadAsync(percent => DispatcherQueue.TryEnqueue(() =>
            {
                if (_update.Phase != UpdatePhase.Downloading) return;
                _update = _update.Downloading(percent);
                ShowUpdate();
            }));
            _update = _update.Restarting();
            ShowUpdate();
            // Windows can't rename a folder a Linux probe runs from: wait for
            // each distro's run and hold them until the app exits; if the
            // install can't be set up, they're free again before we say so (WslHold).
            await WslHold.Install(_hud.WslDistros, TimeSpan.FromMinutes(3), _updater.InstallWhenQuit);
        }
        catch (Exception error)
        {
            _update = _update.DownloadFailed(error.Message);
            ShowUpdate();
            return;
        }
        Quit();
    }

    /// `--update`, from the notification's button or a launch: the same as the
    /// Settings button, after a check if this run hasn't found the version yet.
    private async Task UpdateFromLaunch()
    {
        Navigate("settings");
        if (!_update.CanUpdate) await CheckForUpdates();
        await Update();
    }

    private void ShowUpdate()
    {
        UpdateVersionText.Text = _update.Title;
        UpdateDetailText.Text = _update.Detail(at => HudText.Clock(at, CultureInfo.CurrentCulture));
        CheckUpdatesButton.Visibility = _update.Phase == UpdatePhase.NotInstalled ? Visibility.Collapsed : Visibility.Visible;
        CheckUpdatesButton.IsEnabled = _update.CanCheck;
        UpdateButton.Visibility = _update.Available is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateButton.IsEnabled = _update.CanUpdate;
        var installing = _update.Phase is UpdatePhase.Downloading or UpdatePhase.Restarting;
        UpdateProgress.Visibility = installing ? Visibility.Visible : Visibility.Collapsed;
        UpdateProgress.IsIndeterminate = _update.Phase == UpdatePhase.Restarting;
        UpdateProgress.Value = _update.Percent;
        // Open while a version is offered, unless the person closed it for that version; it follows the download too.
        UpdateBar.IsOpen = _update.Available is { } available && available != _updateBarClosed
            && _update.Phase is UpdatePhase.Available or UpdatePhase.Downloading or UpdatePhase.Restarting or UpdatePhase.Failed;
        UpdateBar.Title = $"ClaudeBar {_update.Available} is available";
        UpdateBar.Message = _update.Phase == UpdatePhase.Available
            ? "Update installs it and restarts ClaudeBar. Your settings and membership stay." : UpdateDetailText.Text;
        UpdateBar.Severity = _update.Phase == UpdatePhase.Failed ? InfoBarSeverity.Warning : InfoBarSeverity.Informational;
        UpdateBarButton.IsEnabled = _update.CanUpdate;
    }

    private async void OnCheckForUpdates(object sender, RoutedEventArgs e) => await Guarded(CheckForUpdates);

    private async void OnUpdate(object sender, RoutedEventArgs e) => await Guarded(Update);

    private void OnUpdateBarClosed(InfoBar sender, InfoBarClosedEventArgs args)
    {
        if (args.Reason == InfoBarCloseReason.CloseButton) _updateBarClosed = _update.Available;
    }
}
