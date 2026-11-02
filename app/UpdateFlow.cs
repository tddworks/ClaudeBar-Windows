namespace ClaudeBar;

internal enum UpdatePhase { NotInstalled, Idle, Checking, UpToDate, Available, Downloading, Restarting, Failed }

internal sealed record UpdateStatus(UpdatePhase Phase, string Current, string? Available = null, int Percent = 0, string? Error = null, DateTimeOffset? CheckedAt = null)
{
    internal static UpdateStatus Start(string current, bool installed) => new(UpdatePhase.Idle, current);
    internal bool CanCheck => false;
    internal bool CanUpdate => false;
    internal string Title => "";
    internal string Detail(Func<DateTimeOffset, string> clock) => "";
    internal UpdateStatus Checking() => this;
    internal UpdateStatus Checked(string? found, DateTimeOffset at) => this;
    internal UpdateStatus CheckFailed(string reason) => this;
    internal UpdateStatus Downloading(int percent) => this;
    internal UpdateStatus DownloadFailed(string reason) => this;
    internal UpdateStatus Restarting() => this;
    internal static bool ShouldNotify(string available, string? notified, string current) => false;
}

internal static class UpdateSchedule
{
    internal enum Outcome { Started, Checked, Busy, Failed }
    internal static TimeSpan After(Outcome outcome) => TimeSpan.Zero;
    internal static bool Busy(int state) => false;
}

internal sealed record UpdateFeed(bool Local, string Location, bool Prereleases)
{
    internal static UpdateFeed Choose(string? local) => new(false, "", false);
}
