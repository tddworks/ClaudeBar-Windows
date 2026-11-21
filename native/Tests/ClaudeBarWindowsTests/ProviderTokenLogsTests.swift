import DataSources
import Foundation
import Leaderboard
import Quotas
import Testing
@testable import ClaudeBarShared

@Suite @MainActor
struct ProviderTokenLogsTests {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent("cbw-home-\(UUID().uuidString)", isDirectory: true)
    private let calendar = DataSources.calendar()

    /// The probe leaves a provider whose log root Windows reads too out of its
    /// token logs (docs/plans/2026-11-03-wsl-design.md, Folders shared with
    /// Windows), so its days aren't counted twice.
    @Test func `should leave a provider in except out of the token logs`() {
        #expect(!ProviderTokenLogs(except: ["claude"], home: home).providersWithLogs.contains("claude"))
        #expect(ProviderTokenLogs(except: ["claude"], home: home).providersWithLogs.contains("codex"))
    }

    /// A test reads token logs from a home of its own: the logs under it, and
    /// what reading them keeps beside them, never the person's.
    @Test func `should read the logs under the home it is given, and keep the closed days there`() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let day = try #require(calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: Date())))
        let log = home.appendingPathComponent(".claude/projects/work/session.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.claudeLine(at: day.addingTimeInterval(12 * 3600), input: 1200, output: 300).utf8).write(to: log)
        let range = DateRange.last(4, endingOn: Date(), calendar: calendar)

        let read = await ProviderTokenLogs(home: home).days(in: range)

        #expect(Self.tokens(of: "claude", on: day, in: read) == 1500)
        let kept = home.appendingPathComponent(".claudebar/usage-history")
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("claude.json").path))
        #expect(try !FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("scans").path).isEmpty)

        // A new process, as the hourly upload is, finds the closed day where
        // the first kept it, with the log gone.
        try FileManager.default.removeItem(at: log)
        #expect(Self.tokens(of: "claude", on: day, in: await ProviderTokenLogs(home: home).days(in: range)) == 1500)
    }

    /// One reply of Claude Code's, as its session log holds it.
    private static func claudeLine(at time: Date, input: Int, output: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"type":"assistant","timestamp":"\#(formatter.string(from: time))","requestId":"req_1","#
            + #""message":{"id":"msg_1","model":"claude-sonnet-4-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
            + "\n"
    }

    private static func tokens(of provider: String, on day: Date, in read: [LoginDays]) -> Int? {
        read.first { $0.providerId == provider }?.days.first { $0.date == day }?.totalTokens
    }
}
