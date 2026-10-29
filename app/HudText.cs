using System.Globalization;

namespace ClaudeBar;

/// The HUD's words for time and for each limit (docs/plans/2026-10-13-hud-design.md):
/// short on the HUD itself, whole sentences for UI Automation.
internal static class HudText
{
    /// The time to a reset, as the HUD's last column shows it: `14m`, `2h 14m`,
    /// `3d 6h`. A part minute counts as a whole one, so it never says `0m`
    /// while the limit hasn't reset yet.
    internal static string Until(TimeSpan left)
    {
        if (left <= TimeSpan.Zero) return "now";
        var minutes = (long)Math.Ceiling(left.TotalMinutes);
        if (minutes < 60) return $"{minutes}m";
        if (minutes < 24 * 60) return $"{minutes / 60}h {minutes % 60:00}m";
        return $"{minutes / (24 * 60)}d {minutes % (24 * 60) / 60}h";
    }

    /// The same, in words: `2 hours 14 minutes`.
    internal static string SpokenUntil(TimeSpan left)
    {
        if (left <= TimeSpan.Zero) return "now";
        var minutes = (long)Math.Ceiling(left.TotalMinutes);
        if (minutes < 60) return Count(minutes, "minute");
        if (minutes < 24 * 60) return minutes % 60 == 0 ? Count(minutes / 60, "hour") : $"{Count(minutes / 60, "hour")} {Count(minutes % 60, "minute")}";
        var hours = minutes % (24 * 60) / 60;
        return hours == 0 ? Count(minutes / (24 * 60), "day") : $"{Count(minutes / (24 * 60), "day")} {Count(hours, "hour")}";
    }

    /// A clock time in the PC's own format: `14:30`, or `2:30 PM`.
    internal static string Clock(DateTimeOffset at, CultureInfo culture) => at.ToLocalTime().ToString("t", culture);

    /// What a line's last column says: when it's back, as a clock time, for a
    /// limit at 0; otherwise the time to its reset; nothing when it has none.
    internal static string Reset(int percentLeft, DateTimeOffset? resetsAt, DateTimeOffset now, CultureInfo culture) => resetsAt switch
    {
        null => "",
        { } at when percentLeft <= 0 => $"back {Clock(at, culture)}",
        { } at => Until(at - now),
    };

    /// A window's name in words: `5-hour limit`, `7-day limit`, or the quota's
    /// own title (`Opus limit`).
    internal static string LimitName(string window, double? seconds)
    {
        if (seconds is > 0 and var length)
        {
            var whole = (long)length;
            if (whole % 86_400 == 0) return $"{whole / 86_400}-day limit";
            if (whole % 3_600 == 0) return $"{whole / 3_600}-hour limit";
            if (whole % 60 == 0) return $"{whole / 60}-minute limit";
        }
        if (window.Length > 1 && long.TryParse(window[..^1], out var count))
        {
            switch (window[^1])
            {
                case 'd': return $"{count}-day limit";
                case 'h': return $"{count}-hour limit";
                case 'm': return $"{count}-minute limit";
            }
        }
        return $"{window} limit";
    }

    /// The sentence UI Automation reads for a line: `Claude, 5-hour limit: 62%
    /// left, resets in 2 hours 14 minutes`.
    internal static string Sentence(string tool, HudData.Line line, DateTimeOffset now, CultureInfo culture)
    {
        var text = $"{tool}, {LimitName(line.Window, line.WindowSeconds)}: ";
        text += line.PercentLeft <= 0
            ? "used up" + (line.ResetsAt is { } back ? $", back at {Clock(back, culture)}" : "")
            : $"{line.PercentLeft}% left" + (line.ResetsAt is { } reset ? $", resets in {SpokenUntil(reset - now)}" : "");
        if (line.RunningHot) text += ", running hot";
        return text;
    }

    /// How long ago the numbers were read: `just now`, `1m ago`, `2h ago`.
    internal static string Ago(TimeSpan since) =>
        since < TimeSpan.FromMinutes(1) ? "just now"
        : since < TimeSpan.FromHours(1) ? $"{(long)since.TotalMinutes}m ago"
        : since < TimeSpan.FromDays(1) ? $"{(long)since.TotalHours}h ago"
        : $"{(long)since.TotalDays}d ago";

    private static string Count(long count, string noun) => count == 1 ? $"1 {noun}" : $"{count} {noun}s";
}
