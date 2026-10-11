import ClaudeBarWindows
import Diagnostics
import Foundation

// Run every hour by Task Scheduler while the person is signed in. Task
// Scheduler is the clock, so this uploads each time: the days from the last
// upload's day, that day included, to today, and the days the server refused.
// Today's totals grow through the day, and a day sent again replaces itself.
let client = Client()
let membership = client.membership()
guard membership.isOn, membership.isJoined else {
    AppLog.network.info("Leaderboard upload skipped: \(membership.isOn ? "not joined" : "turned off")")
    exit(0)
}
let uploader = client.uploader(for: membership)
await uploader.uploadNow()
if let error = uploader.lastError {
    AppLog.network.error("Leaderboard upload failed: \(error.localizedDescription)")
    exit(1)
}
if let failure = client.settings.takeFailure() {
    // Uploaded, but not recorded here: the next run sends the same days again, which replace themselves.
    AppLog.network.error("Leaderboard uploaded, but the settings file wasn't updated: \(failure)")
    exit(2)
}
AppLog.network.info("Leaderboard uploaded by the scheduled task")
exit(0)
