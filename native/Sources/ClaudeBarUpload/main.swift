import ClaudeBarWindows
import Diagnostics
import Foundation

// Run every hour by Task Scheduler while the person is signed in. Task
// Scheduler is the clock, so this uploads each time: the days from the last
// upload's day, that day included, to today, an earlier day that now reads
// larger than the server took, and the days the server refused. Today's
// totals grow through the day, and a day sent again replaces itself.

/// Ends with `code`, once the log has every line: it writes on a queue of its
/// own, which `exit` would end with the outcome line still on it.
func end(_ code: Int32) -> Never {
    AppLog.flush()
    exit(code)
}

let client = Client()
let membership = client.membership()
guard membership.isOn, membership.isJoined else {
    AppLog.network.info("Leaderboard upload skipped: \(membership.isOn ? "not joined" : "turned off")")
    end(0)
}
let uploader = client.uploader(for: membership)
await uploader.uploadNow()
if let error = uploader.lastError {
    AppLog.network.error("Leaderboard upload failed: \(error.localizedDescription)")
    end(1)
}
if let failure = client.settings.takeFailure() {
    // Uploaded, but not recorded here: the next run sends the same days again, which replace themselves.
    AppLog.network.error("Leaderboard uploaded, but the settings file wasn't updated: \(failure)")
    end(2)
}
AppLog.network.info("Leaderboard uploaded by the scheduled task")
end(0)
