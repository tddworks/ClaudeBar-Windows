import Foundation
import Leaderboard
import Quotas
import Testing
@testable import ClaudeBarShared
@testable import ClaudeBarWindows

/// Uploads with a distro's days, as the server sees them
/// (docs/plans/2026-11-03-wsl-design.md, The Leaderboard (phase 2)): each
/// upload is a process of its own, as the hourly uploader is, built from the
/// settings file, the key, this PC's days and the distros' kept days, all in
/// a folder of the test's own. ClaudeBar's upload rules are its own (#703);
/// what these pin is that the distro's days get there, and never twice.
@Suite @MainActor
struct WslUploadTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cbw-wslupload-\(UUID().uuidString)", isDirectory: true)
    private let server = RecordingServer()
    private let keys = MemoryKeys()
    private let pc = FixedLogs()
    private var kept: WslKeptDays { WslKeptDays(folder: folder.appendingPathComponent("days", isDirectory: true)) }
    private let probe: RecordingProbe
    private let calendar = WslKeptDaysTests.calendar("UTC")
    private nonisolated static let utc = TimeZone(identifier: "UTC")!

    init() {
        probe = RecordingProbe(kept: WslKeptDays(folder: folder.appendingPathComponent("days", isDirectory: true)))
    }

    private var settings: SettingsFile {
        SettingsFile(url: folder.appendingPathComponent("settings.json"), lockName: #"Local\ClaudeBar.test."# + folder.lastPathComponent)
    }

    /// 2026-11-`day` at `hour`, UTC.
    private static func at(_ day: Int, _ hour: Int) -> Date { WslKeptDaysTests.at(hour, day: day) }

    private static func label(_ day: Int) -> String { String(format: "2026-11-%02d", day) }

    /// A process's token logs: this PC's, and the distros' after a run in each running one that's on.
    private func logs(at date: Date, running: [String], switches: [String: Bool]) -> DeviceTokenLogs {
        let wsl = WslDays(fresh: true, probe: probe, kept: kept, list: { _ in running }, switches: { switches },
                          zone: { Self.utc }, now: { date }, windows: { [] }, log: { _ in })
        return DeviceTokenLogs(windows: pc, providers: [], wsl: wsl, calendar: { [calendar] in calendar })
    }

    private func membership(at date: Date, logs: DeviceTokenLogs) -> LeaderboardMembership {
        LeaderboardMembership(api: server, keys: keys, settings: settings, logs: logs, machine: FixedMachine(),
                              calendar: calendar, now: { date })
    }

    private func join(at date: Date) async throws {
        try await membership(at: date, logs: logs(at: date, running: [], switches: [:]))
            .join(as: #require(Username("tokenwhale")), sharing: ["claude"])
    }

    /// One hourly upload: what reached the server, `[]` when nothing went.
    @discardableResult
    private func upload(at date: Date, running: [String] = [], switches: [String: Bool] = [:]) async -> [DailyTokens] {
        let logs = logs(at: date, running: running, switches: switches)
        let before = server.uploads.count
        let uploader = LeaderboardUploader(membership: membership(at: date, logs: logs), logs: logs, api: server,
                                           calendar: calendar, now: { date })
        await uploader.uploadNow()
        #expect(uploader.lastError == nil)
        return server.uploads.count > before ? server.uploads.last! : []
    }

    /// The distro's answer for its next run: its `claude` days, read when it answers.
    private func answer(_ distro: String, at date: Date, root: String? = nil, _ days: [Int: Int]) {
        probe.answer(distro, .save(WslKeptDaysTests.entry(distro, zone: "Etc/UTC", at: date,
                                                           roots: root.map { [("claude", $0)] } ?? [],
                                                           days: days.sorted { $0.key < $1.key }.map { WslKeptDaysTests.day("claude", Self.label($0.key), $0.value) })))
    }

    private static func claude(_ day: Int, _ input: Int) -> DailyTokens { WslKeptDaysTests.day("claude", label(day), input) }

    private static let shared = #"D:\shared\.claude\projects"#

    @Test func `should send the days a distro read late whole, this PC's and the distro's`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        pc.set([7: 100, 8: 100, 9: 100], calendar)
        try await join(at: Self.at(10, 9))
        #expect(await upload(at: Self.at(10, 9)) == [Self.claude(7, 100), Self.claude(8, 100), Self.claude(9, 100)])

        answer("Ubuntu", at: Self.at(11, 9), [7: 10, 8: 20, 9: 30])
        let sent = await upload(at: Self.at(11, 9), running: ["Ubuntu"])

        #expect(sent == [Self.claude(7, 110), Self.claude(8, 120), Self.claude(9, 130)])
    }

    @Test func `should not send today smaller when the distro stops`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await join(at: Self.at(12, 0))
        pc.set([12: 100], calendar)
        answer("Ubuntu", at: Self.at(12, 1), [12: 50])
        #expect(await upload(at: Self.at(12, 1), running: ["Ubuntu"]) == [Self.claude(12, 150)])

        pc.set([12: 120], calendar)
        probe.answer("Ubuntu", nil)
        #expect(await upload(at: Self.at(12, 2), running: ["Ubuntu"]) == [Self.claude(12, 170)])
        #expect(probe.calls == ["Ubuntu logsOnly", "Ubuntu logsOnly"])
    }

    @Test func `should keep sending a switched-off distro's frozen days`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await join(at: Self.at(12, 0))
        pc.set([12: 100], calendar)
        answer("Ubuntu", at: Self.at(12, 1), [12: 50])
        #expect(await upload(at: Self.at(12, 1), running: ["Ubuntu"]) == [Self.claude(12, 150)])

        pc.set([12: 120], calendar)
        answer("Ubuntu", at: Self.at(12, 2), [12: 999])
        #expect(await upload(at: Self.at(12, 2), running: ["Ubuntu"], switches: ["Ubuntu": false]) == [Self.claude(12, 170)])
        #expect(probe.calls == ["Ubuntu logsOnly"])
    }

    @Test func `should keep sending the kept days when a run's zone is refused`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await join(at: Self.at(12, 0))
        pc.set([12: 100], calendar)
        answer("Ubuntu", at: Self.at(12, 1), [12: 50])
        #expect(await upload(at: Self.at(12, 1), running: ["Ubuntu"]) == [Self.claude(12, 150)])

        pc.set([12: 120], calendar)
        probe.answer("Ubuntu", .refuse)
        #expect(await upload(at: Self.at(12, 2), running: ["Ubuntu"]) == [Self.claude(12, 170)])
    }

    @Test func `should send an earlier day again whole when the distro's part of it grew`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await join(at: Self.at(9, 0))
        pc.set([9: 100], calendar)
        answer("Ubuntu", at: Self.at(9, 20), [9: 10])
        #expect(await upload(at: Self.at(9, 20), running: ["Ubuntu"]) == [Self.claude(9, 110)])
        // The next day, day 9 is the last upload's and goes as read; after it, an earlier day.
        #expect(await upload(at: Self.at(10, 9)) == [Self.claude(9, 110)])

        answer("Ubuntu", at: Self.at(11, 9), [9: 30])
        #expect(await upload(at: Self.at(11, 9), running: ["Ubuntu"]) == [Self.claude(9, 130)])
    }

    @Test func `should never send an earlier day smaller, even with the kept days gone`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await join(at: Self.at(9, 0))
        pc.set([9: 100], calendar)
        answer("Ubuntu", at: Self.at(9, 20), [9: 10])
        #expect(await upload(at: Self.at(9, 20), running: ["Ubuntu"]) == [Self.claude(9, 110)])
        #expect(await upload(at: Self.at(10, 9)) == [Self.claude(9, 110)])

        try FileManager.default.removeItem(at: folder.appendingPathComponent("days"))
        pc.set([9: 100, 11: 5], calendar)
        #expect(await upload(at: Self.at(11, 9)) == [Self.claude(11, 5)])
    }

    /// A record v0.1.16 wrote, without `sent`: the days before its last
    /// upload's go only when refused, the distro's too (*Decisions*, 1).
    @Test func `should hold a distro's days before the last upload of a record from before sent`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await join(at: Self.at(10, 0))
        #expect(await upload(at: Self.at(10, 9)) == [])
        let record = try #require(settings.leaderboardRecord())
        settings.saveLeaderboardRecord(LeaderboardRecord(username: record.username, sharing: record.sharing, visible: record.visible,
                                                         lastUpload: Self.at(10, 9), machine: record.machine))
        #expect(settings.leaderboardRecord()?.sent == nil)

        answer("Ubuntu", at: Self.at(11, 9), [8: 40, 10: 60])
        #expect(await upload(at: Self.at(11, 9), running: ["Ubuntu"]) == [Self.claude(10, 60)])
    }

    /// *Decisions*, 5: leaving deletes nothing on this PC.
    @Test func `should keep the kept days on leaving, and send them with this PC's on joining again`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await join(at: Self.at(12, 0))
        answer("Ubuntu", at: Self.at(12, 1), [12: 50])
        #expect(await upload(at: Self.at(12, 1), running: ["Ubuntu"]) == [Self.claude(12, 50)])
        let before = kept.all()

        try await membership(at: Self.at(12, 2), logs: logs(at: Self.at(12, 2), running: [], switches: [:])).leave()

        #expect(!before.isEmpty)
        #expect(kept.all() == before)
        pc.set([12: 100, 13: 7], calendar)
        try await join(at: Self.at(13, 9))
        #expect(await upload(at: Self.at(13, 9)) == [Self.claude(12, 150), Self.claude(13, 7)])
    }

    /// Design, *A log root two distros read counts once*.
    @Test func `should count a folder two distros read once, from the latest reading`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await join(at: Self.at(12, 0))
        pc.set([12: 100], calendar)
        answer("Ubuntu", at: Self.at(12, 1), root: Self.shared, [12: 50])
        answer("Debian", at: Self.at(12, 1), root: Self.shared, [12: 50])
        #expect(await upload(at: Self.at(12, 1), running: ["Ubuntu", "Debian"]) == [Self.claude(12, 150)])

        answer("Debian", at: Self.at(12, 2), root: Self.shared, [12: 70])
        probe.answer("Ubuntu", .fail("ClaudeBar couldn't run in Ubuntu: it stopped"))
        #expect(await upload(at: Self.at(12, 2), running: ["Ubuntu", "Debian"]) == [Self.claude(12, 170)])

        answer("Ubuntu", at: Self.at(12, 3), root: Self.shared, [12: 80])
        #expect(await upload(at: Self.at(12, 3), running: ["Ubuntu", "Debian"], switches: ["Debian": false]) == [Self.claude(12, 180)])

        // The next day, both stopped: yesterday goes as read, the 180 the server took.
        pc.set([12: 100, 13: 1], calendar)
        #expect(await upload(at: Self.at(13, 1)) == [Self.claude(12, 180), Self.claude(13, 1)])
        // Its latest reading is Ubuntu's 80, which went as 180: it isn't sent again.
        #expect(await upload(at: Self.at(13, 2)) == [Self.claude(13, 1)])
        // An Ubuntu run reading yesterday as 90 sends it as 190, never 260.
        answer("Ubuntu", at: Self.at(13, 3), root: Self.shared, [12: 90])
        #expect(await upload(at: Self.at(13, 3), running: ["Ubuntu"]) == [Self.claude(12, 190), Self.claude(13, 1)])
    }

    /// A tool deleted lines in between: one reader of that folder would send 30.
    @Test func `should count a newer, smaller reading of a folder two distros read`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await join(at: Self.at(12, 0))
        pc.set([12: 100], calendar)
        answer("Debian", at: Self.at(12, 1), root: Self.shared, [12: 100])
        #expect(await upload(at: Self.at(12, 1), running: ["Debian"]) == [Self.claude(12, 200)])

        answer("Ubuntu", at: Self.at(12, 2), root: Self.shared, [12: 30])
        #expect(await upload(at: Self.at(12, 2), running: ["Ubuntu"]) == [Self.claude(12, 130)])
    }
}

/// This PC's `claude` days, by hand.
@MainActor
private final class FixedLogs: TokenLogs {
    private var logins: [LoginDays] = []
    var providersWithLogs: Set<String> { ["claude"] }

    /// `days`: day of November 2026 to input tokens.
    func set(_ days: [Int: Int], _ calendar: Calendar) {
        logins = [LoginDays(providerId: "claude", days: days.sorted { $0.key < $1.key }.flatMap {
            WslKeptDaysTests.pc(String(format: "2026-11-%02d", $0.key), $0.value, calendar).days
        })]
    }

    func days(in range: DateRange) async -> [LoginDays] { logins.map { $0.within(range) } }
}

private struct FixedMachine: MachineIdentity {
    var hardwareUUID: String? { "4C4C4544-0042-3510-8048-B3C04F4A3133" }
    var model: DeviceLabel { DeviceLabel("Windows PC")! }
}

private final class MemoryKeys: SigningKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    func load() -> Data? { lock.withLock { stored } }
    func save(_ rawKey: Data) { lock.withLock { stored = rawKey } }
    func delete() { lock.withLock { stored = nil } }
}

/// A server that takes every call and records each upload's days.
private final class RecordingServer: LeaderboardAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[DailyTokens]] = []
    var uploads: [[DailyTokens]] { lock.withLock { recorded } }

    func join(username: String, publicKey: String, label: String) async throws {}
    func upload(_ days: [DailyTokens], as credentials: MemberCredentials) async throws -> [RefusedDay] {
        lock.withLock { recorded.append(days) }
        return []
    }
    func me(period: BoardPeriod, provider: String?, as credentials: MemberCredentials) async throws -> MemberSummary {
        MemberSummary(onBoard: nil, days: [], visible: true)
    }
    func export(as credentials: MemberCredentials) async throws -> Data { Data("{}".utf8) }
    func update(_ change: MemberChange, as credentials: MemberCredentials) async throws {}
    func leave(as credentials: MemberCredentials) async throws {}
    func board(period: BoardPeriod, provider: String?) async throws -> [Board.Member] { [] }
    func globe(period: BoardPeriod) async throws -> GlobeSummary { GlobeSummary(countries: [], present: []) }
    func requestDevice(publicKey: String, label: String) async throws -> DeviceAuthorization { throw LeaderboardError.unreachable }
    func approval(of key: SigningKey) async throws -> DeviceApproval { .waiting }
    func pendingDevice(code: DeviceCode, as credentials: MemberCredentials) async throws -> PendingDevice { throw LeaderboardError.unknownCode }
    func approveDevice(code: DeviceCode, as credentials: MemberCredentials) async throws -> Device { throw LeaderboardError.unknownCode }
    func removeDevice(_ publicKey: String, as credentials: MemberCredentials) async throws {}
    func deleteDays(of publicKey: String, provider: String?, day: String?, as credentials: MemberCredentials) async throws {}
}
