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
AppLog.network.info("Leaderboard uploaded by the scheduled task")
exit(0)
