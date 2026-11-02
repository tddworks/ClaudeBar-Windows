using Velopack;

namespace ClaudeBar;

/// Where an update stands (docs/plans/2026-11-02-updates-design.md, What the person sees).
internal enum UpdatePhase { NotInstalled, Idle, Checking, UpToDate, Available, Downloading, Restarting, Failed }

/// What Settings → Updates shows and offers. Each step returns the next
/// status, or this one when the step isn't allowed now: no check while one
/// runs or an update downloads, no download without a version found.
/// `Available` stays through a failed check or download, so *Update* is still offered.
internal sealed record UpdateStatus(UpdatePhase Phase, string Current, string? Available = null, int Percent = 0, string? Error = null, DateTimeOffset? CheckedAt = null)
{
    /// A copy Setup didn't install (the zip, `build.ps1`'s output) has nothing to update.
    internal static UpdateStatus Start(string current, bool installed) =>
        new(installed ? UpdatePhase.Idle : UpdatePhase.NotInstalled, current);

    internal bool CanCheck => Phase is UpdatePhase.Idle or UpdatePhase.UpToDate or UpdatePhase.Available or UpdatePhase.Failed;

    internal bool CanUpdate => Available is not null && Phase is UpdatePhase.Available or UpdatePhase.Failed;

    internal string Title => $"ClaudeBar for Windows {Current}";

    /// The line under the version; `clock` says when the last check was.
    internal string Detail(Func<DateTimeOffset, string> clock) => Phase switch
    {
        UpdatePhase.NotInstalled => "Updates come with the installed app: install it with Setup.exe from Releases.",
        UpdatePhase.Idle => "Checks for updates at start and every 4 hours.",
        UpdatePhase.Checking => "Checking for updates…",
        UpdatePhase.UpToDate => $"Up to date · checked {clock(CheckedAt ?? DateTimeOffset.Now)}",
        UpdatePhase.Available => $"{Available} is available. Update downloads it, installs it and restarts ClaudeBar.",
        UpdatePhase.Downloading => $"Downloading {Available}… {Percent}%",
        UpdatePhase.Restarting => $"Installing {Available} and restarting ClaudeBar…",
        _ => Available is null ? Error ?? "" : $"{Error} {Available} is still available.",
    };

    internal UpdateStatus Checking() => CanCheck ? this with { Phase = UpdatePhase.Checking, Error = null } : this;

    /// What the check found: a newer version, or none.
    internal UpdateStatus Checked(string? found, DateTimeOffset at) => Phase != UpdatePhase.Checking ? this
        : this with { Phase = found is null ? UpdatePhase.UpToDate : UpdatePhase.Available, Available = found, CheckedAt = at };

    internal UpdateStatus CheckFailed(string reason) => Phase != UpdatePhase.Checking ? this
        : this with { Phase = UpdatePhase.Failed, Error = $"Couldn't check for updates. {reason}" };

    internal UpdateStatus Downloading(int percent) => CanUpdate || Phase == UpdatePhase.Downloading
        ? this with { Phase = UpdatePhase.Downloading, Percent = Math.Clamp(percent, 0, 100), Error = null }
        : this;

    /// The download failed, or `Update.exe` couldn't start after it: nothing quits, so *Update* is offered again.
    internal UpdateStatus DownloadFailed(string reason) => Phase is not (UpdatePhase.Downloading or UpdatePhase.Restarting) ? this
        : this with { Phase = UpdatePhase.Failed, Error = $"Couldn't update. {reason}" };

    internal UpdateStatus Restarting() => Phase != UpdatePhase.Downloading ? this : this with { Phase = UpdatePhase.Restarting };

    /// One notification per version: one newer than the installed one and than
    /// the last one notified (`app.json`'s `updateNotified`), by SemVer.
    internal static bool ShouldNotify(string available, string? notified, string current)
    {
        if (!SemanticVersion.TryParse(available, out var version)) return available != notified && available != current;
        bool Newer(string? than) => than is null || !SemanticVersion.TryParse(than, out var other) || version > other;
        return Newer(current) && Newer(notified);
    }
}

/// When the next check runs: two minutes after a start, so it doesn't compete
/// with the first reading; every 4 hours after; sooner after a failure, or
/// while the person is busy in a full-screen app, a game or a presentation.
internal static class UpdateSchedule
{
    internal enum Outcome { Started, Checked, Busy, Failed }

    internal static TimeSpan After(Outcome outcome) => outcome switch
    {
        Outcome.Started => TimeSpan.FromMinutes(2),
        Outcome.Busy => TimeSpan.FromMinutes(15),
        Outcome.Failed => TimeSpan.FromHours(1),
        _ => TimeSpan.FromHours(4),
    };

    /// `SHQueryUserNotificationState`'s answer: QUNS_BUSY (a full-screen app),
    /// QUNS_RUNNING_D3D_FULL_SCREEN (a game), QUNS_PRESENTATION_MODE, QUNS_APP
    /// (a full-screen Store app).
    internal static bool Busy(int state) => state is 2 or 3 or 4 or 7;
}

/// Where updates come from: this repo's releases, pre-releases included (every
/// release so far is one; stable ones are read either way), or a local folder
/// that `CLAUDEBAR_UPDATE_FEED` names, for trying an update before a release.
internal sealed record UpdateFeed(bool Local, string Location, bool Prereleases)
{
    internal const string Repository = "https://github.com/tddworks/ClaudeBar-Windows";

    internal static UpdateFeed Choose(string? local) => string.IsNullOrWhiteSpace(local)
        ? new(false, Repository, true)
        : new(true, local.Trim(), true);
}
