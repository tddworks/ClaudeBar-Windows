import Foundation
import Leaderboard
import Quotas
import Testing
@testable import ClaudeBarWindows

/// What a restart, or the hourly uploader's own process, finds: the
/// membership the app joined, from the settings file and the key store alone.
@MainActor
@Suite
struct MembershipRestartTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cbw-\(UUID().uuidString)", isDirectory: true)
    private let keys = MemoryKeyStore()
    private let server = AcceptingServer()

    /// A client as a new process builds it: nothing in memory but the file and the key.
    private func process() -> Client {
        Client(api: server, keys: keys,
               settings: SettingsFile(url: folder.appendingPathComponent("settings.json"), lockName: #"Local\ClaudeBar.test."# + folder.lastPathComponent),
               logs: ProviderTokenLogs(), machine: FixedMachine())
    }

    @Test func `should still be the member it joined as, sharing the same providers, after a restart`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = process().membership()
        try await app.join(as: #require(Username("tokenwhale")), sharing: ["omp"])

        let restarted = process().membership()

        #expect(restarted.isJoined)
        #expect(restarted.username?.value == "tokenwhale")
        #expect(restarted.sharing == ["omp"])
    }

    /// The uploader runs in a process of its own: it uploads as the member,
    /// and the app, reading afresh, sees when.
    @Test func `should upload from the uploader's own process, and the app see the upload after it`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await process().membership().join(as: #require(Username("tokenwhale")), sharing: ["omp"])

        let uploaderProcess = process()
        let uploader = uploaderProcess.uploader(for: uploaderProcess.membership())
        await uploader.uploadNow()

        #expect(uploader.lastError == nil)
        #expect(process().membership().lastUpload != nil)
    }

    @Test func `should forget the membership and the key on leaving, for every process after`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try await process().membership().join(as: #require(Username("tokenwhale")), sharing: ["omp"])

        try await process().membership().leave()

        #expect(!process().membership().isJoined)
        #expect(keys.load() == nil)
    }
}

private struct FixedMachine: MachineIdentity {
    var model: DeviceLabel { DeviceLabel("Windows PC")! }
}

private final class MemoryKeyStore: SigningKeyStore, @unchecked Sendable {
    private var stored: Data?
    func load() -> Data? { stored }
    func save(_ rawKey: Data) { stored = rawKey }
    func delete() { stored = nil }
}

/// A server that takes every call.
private final class AcceptingServer: LeaderboardAPI, @unchecked Sendable {
    func join(username: String, publicKey: String, label: String) async throws {}
    func upload(_ days: [DailyTokens], as credentials: MemberCredentials) async throws -> [RefusedDay] { [] }
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
