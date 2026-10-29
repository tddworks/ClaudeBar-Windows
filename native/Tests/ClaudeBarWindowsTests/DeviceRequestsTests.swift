import Foundation
import Leaderboard
import Testing
@testable import ClaudeBarWindows

/// Asking for a code is a round trip: one cancelled or replaced meanwhile can
/// answer last, and must not take the place of the code the window shows.
@MainActor
@Suite
struct DeviceRequestsTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cbw-\(UUID().uuidString)", isDirectory: true)
    private let server = HeldServer()

    private func membership() -> LeaderboardMembership {
        Client(api: server, keys: NoKeys(),
               settings: SettingsFile(url: folder.appendingPathComponent("settings.json"),
                                      lockName: #"Local\ClaudeBar.test."# + folder.lastPathComponent),
               logs: ProviderTokenLogs(), machine: PC()).membership()
    }

    private func asked(_ count: Int) async {
        while server.asked < count { await Task.yield() }
    }

    @Test func `should keep the newer code when a cancelled ask answers after it`() async throws {
        let requests = DeviceRequests()
        let older = Task { try await requests.request(through: membership()) }
        await asked(1)
        requests.cancel()
        let newer = Task { try await requests.request(through: membership()) }
        await asked(2)

        server.answer(1, code: "WDJB-MJHT")
        let shown = try await newer.value
        server.answer(0, code: "BCDF-GHJK")
        let late = try await older.value

        #expect(late == nil)
        #expect(shown?.code == DeviceCode("WDJB-MJHT"))
        #expect(requests.current === shown)
    }

    @Test func `should keep the newer code when a replaced ask answers after it`() async throws {
        let requests = DeviceRequests()
        let older = Task { try await requests.request(through: membership()) }
        await asked(1)
        let newer = Task { try await requests.request(through: membership()) }
        await asked(2)

        server.answer(1, code: "WDJB-MJHT")
        let shown = try await newer.value
        server.answer(0, code: "BCDF-GHJK")

        #expect(try await older.value == nil)
        #expect(requests.current === shown)
    }

    @Test func `should keep a newer code when an older request ends`() async throws {
        let requests = DeviceRequests()
        let first = Task { try await requests.request(through: membership()) }
        await asked(1)
        server.answer(0, code: "BCDF-GHJK")
        let ended = try #require(try await first.value)
        let second = Task { try await requests.request(through: membership()) }
        await asked(2)
        server.answer(1, code: "WDJB-MJHT")
        let shown = try await second.value

        requests.end(ended)

        #expect(requests.current === shown)
    }
}

private struct PC: MachineIdentity {
    var hardwareUUID: String? { "4C4C4544-0042-3510-8048-B3C04F4A3133" }
    var model: DeviceLabel { DeviceLabel("Windows PC")! }
}

private final class NoKeys: SigningKeyStore, @unchecked Sendable {
    func load() -> Data? { nil }
    func save(_ rawKey: Data) {}
    func delete() {}
}

/// A server that holds each code request until the test answers it.
private final class HeldServer: LeaderboardAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [CheckedContinuation<DeviceAuthorization, any Error>] = []

    var asked: Int { lock.withLock { held.count } }

    func answer(_ index: Int, code: String) {
        let request = lock.withLock { held[index] }
        request.resume(returning: DeviceAuthorization(code: DeviceCode(code)!, expiresIn: 600, interval: 5))
    }

    func requestDevice(publicKey: String, label: String) async throws -> DeviceAuthorization {
        try await withCheckedThrowingContinuation { request in lock.withLock { held.append(request) } }
    }

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
    func approval(of key: SigningKey) async throws -> DeviceApproval { .waiting }
    func pendingDevice(code: DeviceCode, as credentials: MemberCredentials) async throws -> PendingDevice { throw LeaderboardError.unknownCode }
    func approveDevice(code: DeviceCode, as credentials: MemberCredentials) async throws -> Device { throw LeaderboardError.unknownCode }
    func removeDevice(_ publicKey: String, as credentials: MemberCredentials) async throws {}
    func deleteDays(of publicKey: String, provider: String?, day: String?, as credentials: MemberCredentials) async throws {}
}
