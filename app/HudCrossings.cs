namespace ClaudeBar;

/// A crossing that notifies (design, Taskbar and notifications): a limit
/// into critical (under 20%), into depleted (0%), or out of depleted.
internal enum Crossing { Low, Out, Back }

/// Where a limit was at the last reading, kept in app.json: its status, the
/// reset its window ends at, the crossings already notified in that window,
/// and until when the person asked for quiet.
internal sealed record KeptLine(string Status, DateTimeOffset? ResetsAt, IReadOnlyList<Crossing> Notified, DateTimeOffset? QuietUntil = null);

/// A limit in this reading: its key (`claude/5h`), status and reset.
internal sealed record LineNow(string Key, string Status, DateTimeOffset? ResetsAt);

/// When the HUD notifies (Task 11): on a crossing into critical, into
/// depleted, or out of depleted, compared with the last reading kept. Never
/// twice for the same limit and crossing in one window, and never for a limit
/// seen for the first time, which crossed nothing.
internal static class HudCrossings
{
    /// A reset that moves later by more than this starts a new window; less is the same reset, read again.
    private static readonly TimeSpan NewWindow = TimeSpan.FromMinutes(5);

    internal static (IReadOnlyList<(string Key, Crossing Crossing)> Notify, Dictionary<string, KeptLine> Kept) Next(
        IReadOnlyDictionary<string, KeptLine> kept, IEnumerable<LineNow> lines, DateTimeOffset now)
    {
        var notify = new List<(string, Crossing)>();
        // A limit missing from this reading (a tool that failed) keeps where it was.
        var next = new Dictionary<string, KeptLine>(kept);
        foreach (var line in lines)
        {
            if (!kept.TryGetValue(line.Key, out var before))
            {
                next[line.Key] = new KeptLine(line.Status, line.ResetsAt, Array.Empty<Crossing>());
                continue;
            }
            var newWindow = line.ResetsAt is { } reset && (before.ResetsAt is not { } was || reset - was > NewWindow);
            var notified = newWindow ? Array.Empty<Crossing>() : before.Notified;
            var quiet = before.QuietUntil is { } until && now < until ? before.QuietUntil : null;
            if (Of(before.Status, line.Status) is { } crossing && !notified.Contains(crossing))
            {
                if (quiet is null) notify.Add((line.Key, crossing));
                notified = notified.Append(crossing).ToList();
            }
            next[line.Key] = new KeptLine(line.Status, line.ResetsAt, notified, quiet);
        }
        return (notify, next);
    }

    /// The crossing from one status to the next, if it's one that notifies.
    internal static Crossing? Of(string before, string now) =>
        before == "depleted" && now != "depleted" ? Crossing.Back
        : now == "depleted" && before != "depleted" ? Crossing.Out
        : now == "critical" && before is "healthy" or "warning" ? Crossing.Low
        : null;
}
