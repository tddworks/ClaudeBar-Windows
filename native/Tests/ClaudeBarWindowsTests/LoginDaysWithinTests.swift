import Foundation
import Leaderboard
import Quotas
import Testing
@testable import ClaudeBarWindows

/// The join page's 7 days come from the 30 it already read, not a second read
/// of every log: on a PC with gigabytes of omp sessions, each read takes
/// tens of seconds.
@Suite
struct LoginDaysWithinTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    private func day(_ text: String) -> Date {
        let parts = text.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    private func stat(_ text: String) -> DailyUsageStat {
        DailyUsageStat(date: day(text), totalCost: 0, totalTokens: 10, workingTime: 0, sessionCount: 1)
    }

    @Test
    func `should keep the days from the range's first through its last, and drop the one before`() {
        let month = LoginDays(providerId: "omp", days: ["2026-10-20", "2026-10-21", "2026-10-24", "2026-10-27"].map(stat))
        let week = DateRange.last(7, endingOn: day("2026-10-27"), calendar: calendar)

        let kept = month.within(week)

        #expect(kept.providerId == "omp")
        #expect(kept.days.map(\.date) == [day("2026-10-21"), day("2026-10-24"), day("2026-10-27")])
    }
}
