namespace ClaudeBar;

/// A crossing that notifies (design, Taskbar and notifications): a limit
/// into critical (under 20%, or under pace-aware when it runs out within a
/// tenth of its window), into depleted (0%), or out of depleted.
internal enum Crossing { Low, Out, Back }

/// Where a limit was at the last reading, kept in app.json: its status, the
/// reset its window ends at (one still ahead when it was read, or none), the
/// crossings already notified in that window, and until when the person asked
/// for quiet.
internal sealed record KeptLine(string Status, DateTimeOffset? ResetsAt, IReadOnlyList<Crossing> Notified, DateTimeOffset? QuietUntil = null);

/// A limit in this reading: its key (`claude/session`, HudData.Key), status and reset.
internal sealed record LineNow(string Key, string Status, DateTimeOffset? ResetsAt);

/// When the HUD notifies (Task 11): on a crossing into critical, into
/// depleted, or out of depleted, compared with the last reading kept. Never
/// twice for the same limit and crossing in one window, and never for a limit
/// seen for the first time, which crossed nothing. Under pace-aware, critical
/// follows the time left until it runs out, so a pause and a resume flip a
/// limit between warning and critical; as the Mac's status alerts (ClaudeBar
/// #710, #711), a window ends at its reset, or when the reset moves later;
/// a limit kept with no reset takes the first one ahead it reports, and one
/// with none ends its window once it reads healthy. A reset already past says
/// nothing about the window.
internal static class HudCrossings
{
    /// A reset that moves later by more than this starts a new window; less is the same reset, read again.
    private static readonly TimeSpan NewWindow = TimeSpan.FromMinutes(5);

    internal static (IReadOnlyList<(string Key, Crossing Crossing)> Notify, Dictionary<string, KeptLine> Kept) Next(
        IReadOnlyDictionary<string, KeptLine> kept, IEnumerable<LineNow> lines, DateTimeOffset now)
    {
        var notify = new List<(string, Crossing)>();
        var reading = lines.ToList();
        // A limit missing from this reading keeps where it was while its login is missing too (it
        // failed); a login that answered without it no longer has it, so it goes, as do keys of an
        // earlier shape (`omp/Kimi 7d`, before keys were ClaudeBar's own).
        var answered = reading.Select(line => Login(line.Key)).ToHashSet();
        var next = kept.Where(pair => !answered.Contains(Login(pair.Key))).ToDictionary(pair => pair.Key, pair => pair.Value);
        foreach (var line in reading)
        {
            // A reset already past says nothing about the window.
            var ahead = line.ResetsAt is { } reported && reported > now ? line.ResetsAt : null;
            if (!kept.TryGetValue(line.Key, out var before))
            {
                next[line.Key] = new KeptLine(line.Status, ahead, Array.Empty<Crossing>());
                continue;
            }
            var newWindow = before.ResetsAt is { } was
                ? now >= was || (ahead is { } reset && reset - was > NewWindow)
                : ahead is null && line.Status == "healthy";
            var notified = newWindow ? Array.Empty<Crossing>() : before.Notified;
            var quiet = before.QuietUntil is { } until && now < until ? before.QuietUntil : null;
            if (Of(before.Status, line.Status) is { } crossing && !notified.Contains(crossing))
            {
                if (quiet is null) notify.Add((line.Key, crossing));
                notified = notified.Append(crossing).ToList();
            }
            next[line.Key] = new KeptLine(line.Status, ahead ?? (newWindow ? null : before.ResetsAt), notified, quiet);
        }
        return (notify, next);
    }

    /// *Quiet until reset* on one limit: no notification about it until its
    /// reset, or for 5 hours when it states none; every other limit as it was.
    internal static Dictionary<string, KeptLine> Quiet(IReadOnlyDictionary<string, KeptLine> kept, string key, DateTimeOffset now)
    {
        var next = new Dictionary<string, KeptLine>(kept);
        if (next.TryGetValue(key, out var line)) next[key] = line with { QuietUntil = line.ResetsAt ?? now.AddHours(5) };
        return next;
    }

    /// The login a key belongs to: `omp` for `omp/time:Claude 5h`.
    private static string Login(string key) => key.IndexOf('/') is > 0 and var slash ? key[..slash] : key;

    /// The crossing from one status to the next, if it's one that notifies.
    internal static Crossing? Of(string before, string now) =>
        before == "depleted" && now != "depleted" ? Crossing.Back
        : now == "depleted" && before != "depleted" ? Crossing.Out
        : now == "critical" && before is "healthy" or "warning" ? Crossing.Low
        : null;
}
