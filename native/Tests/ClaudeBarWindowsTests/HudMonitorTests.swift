import DataSources
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Monitoring
import Providers
import Quotas
import Testing
@testable import ClaudeBarWindows

/// The HUD's reading over ClaudeBar's own monitor, from real providers whose
/// connections are stubbed: what crosses to the app as JSON, when it reads,
/// and why a tool has no numbers.
@MainActor
@Suite
struct HudMonitorTests {
    private let server = Answers()
    private let hour = 3600.0
    /// ClaudeBar's usage JSON carries whole seconds.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())

    private func hud(_ products: [(id: String, ready: Bool)]) -> HudMonitor {
        // No settings file: every default applies, as on a PC ClaudeBar's Mac app never ran on.
        let settings = ClaudeBarSettings(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("cbw-\(UUID().uuidString).json"))
        let made = products.map { stubbed($0.id, ready: $0.ready, settings: settings) }
        let monitor = QuotaMonitor(providers: Providers(made, settings: settings, make: { _ in fatalError("no adding in tests") }),
                                   clock: Parked(), settingsRepository: settings, statusPolicy: { .absolute })
        return HudMonitor(monitor: monitor)
    }

    private func stubbed(_ id: String, ready: Bool, settings: ClaudeBarSettings) -> Provider {
        let json = """
        {"profile":{"id":"\(id)","name":"\(id.prefix(1).uppercased() + id.dropFirst())","links":{}},
         "dataSources":[{"kind":"stub","credential":{"environment":"STUB_READY"},
                         "fetch":{"http":{"url":"https://stub.invalid/\(id)"}},"mapping":{"usage":{}}}],
         "defaultDataSource":"stub"}
        """
        let definition = try! ProviderDefinition.parse(Data(json.utf8), origin: .custom)
        let server = server
        return Provider(definition: definition, settings: settings, accounts: [], makeDataSource: { source, _ in
            DataSources.make(source, providerId: id, cliExecutor: NoCLI(), network: server,
                             makeTransport: { _, _, _, _ in throw UsageError.executionFailed("no RPC in a stub") },
                             environment: { $0 == "STUB_READY" && ready ? "ready" : nil },
                             homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
        })
    }

    /// The reply as the app gets it: through JSON text and back.
    private func sent(_ answer: HudMonitor.Answer) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: answer.json())
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A JSON number, whichever type JSONSerialization gave it.
    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            try #require(Date() < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func `should send each tool's limits as JSON, every date in seconds since 1970`() async throws {
        server.answer("claude", ["quotas": [["type": "session", "percentRemaining": 62.7, "resetsAt": now.addingTimeInterval(2 * hour)],
                                            ["type": "weekly", "percentRemaining": 71, "resetsAt": now.addingTimeInterval(80 * hour)]]])
        server.answer("codex", ["quotas": [["type": "session", "percentRemaining": 12, "resetsAt": now.addingTimeInterval(1 * hour)]]])
        let hud = hud([("claude", true), ("codex", true)])

        let json = try sent(await hud.refresh())

        let reading = try #require(json["reading"] as? [String: Any])
        let tools = try #require(reading["tools"] as? [[String: Any]])
        #expect(tools.map { $0["id"] as? String } == ["claude", "codex"])
        let lines = try #require(tools[0]["lines"] as? [[String: Any]])
        for key in ["window", "percentLeft", "resetsAt", "status", "runningHot", "tick", "strip"] {
            #expect(lines.allSatisfy { $0[key] != nil }, "every line has \(key)")
        }
        #expect(lines.map { $0["window"] as? String } == ["5h", "7d"])
        #expect(lines.map { number($0["percentLeft"]) } == [62, 71])
        #expect(lines.map { number($0["resetsAt"]) } == [now.addingTimeInterval(2 * hour).timeIntervalSince1970,
                                                            now.addingTimeInterval(80 * hour).timeIntervalSince1970])
        #expect(lines.map { $0["status"] as? String } == ["healthy", "healthy"])
        let codex = try #require(tools[1]["lines"] as? [[String: Any]])
        #expect(codex[0]["status"] as? String == "critical")
        #expect(reading["worst"] as? String == "critical")
        let readAt = try #require(number(json["readAt"]))
        #expect(abs(readAt - Date().timeIntervalSince1970) < 60)
        #expect((json["problems"] as? [Any])?.isEmpty == true)
        let looks = try #require(json["looks"] as? [[String: Any]])
        #expect(looks.map { $0["id"] as? String } == ["claude", "codex"])
        #expect(looks.map { $0["name"] as? String } == ["Claude", "Codex"])
    }

    @Test func `should answer at once from the numbers it has, and start reading in the background`() async throws {
        server.answer("claude", ["quotas": [["type": "session", "percentRemaining": 62, "resetsAt": now.addingTimeInterval(2 * hour)]]])
        server.answer("codex", ["quotas": [["type": "session", "percentRemaining": 88, "resetsAt": now.addingTimeInterval(4 * hour)]]])
        let hud = hud([("claude", true), ("codex", true)])

        let first = hud.answer()

        #expect(first.reading.tools.isEmpty)
        #expect(first.problems.map(\.kind) == ["reading", "reading"])
        #expect(first.readAt == nil)
        #expect(try sent(first)["readAt"] is NSNull)
        try await until { hud.answer().reading.tools.count == 2 }
        #expect(hud.answer().reading.tools.map { $0.lines[0].percentLeft } == [62, 88])
        #expect(server.asked("claude") == 1, "one background refresh, however often it is asked")
    }

    @Test func `should refresh every tool before it answers a refresh`() async throws {
        server.answer("claude", ["quotas": [["type": "session", "percentRemaining": 62, "resetsAt": now.addingTimeInterval(2 * hour)]]])
        let hud = hud([("claude", true)])
        _ = await hud.refresh()

        server.answer("claude", ["quotas": [["type": "session", "percentRemaining": 30, "resetsAt": now.addingTimeInterval(2 * hour)]]])
        let after = await hud.refresh()

        #expect(after.reading.tools[0].lines[0].percentLeft == 30)
    }

    @Test func `should say why a tool has no numbers: not set up, signed out or failed`() async throws {
        server.answer("amp", ["quotas": [["type": "session", "percentRemaining": 62, "resetsAt": now.addingTimeInterval(2 * hour)]]])
        server.refuse("grok", status: 401)
        server.refuse("zai", status: 500)
        let hud = hud([("amp", true), ("kimi", false), ("grok", true), ("zai", true)])

        let answer = await hud.refresh()

        #expect(answer.reading.tools.map(\.id) == ["amp"])
        #expect(answer.problems.map(\.id) == ["kimi", "grok", "zai"])
        #expect(answer.problems.map(\.kind) == ["notSetUp", "signedOut", "failed"])
        #expect(answer.problems.allSatisfy { !$0.message.isEmpty })
        #expect(answer.looks.map(\.id) == ["amp", "kimi", "grok", "zai"])
    }
}

/// The stubbed servers: each provider's URL answers with ClaudeBar's usage
/// JSON, or with an HTTP status, and counts how often it was asked.
private final class Answers: NetworkClient {
    private struct State {
        var bodies: [String: [String: Any]] = [:]
        var statuses: [String: Int] = [:]
        var asked: [String: Int] = [:]
    }

    private let lock = NSLock()
    private var state = State()

    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    func answer(_ id: String, _ usage: [String: Any]) { locked { $0.bodies[id] = usage } }
    func refuse(_ id: String, status: Int) { locked { $0.statuses[id] = status } }
    func asked(_ id: String) -> Int { locked { $0.asked[id] ?? 0 } }

    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let id = url.lastPathComponent
        let (body, status) = locked { state -> ([String: Any], Int) in
            state.asked[id, default: 0] += 1
            return (state.bodies[id] ?? [:], state.statuses[id] ?? 200)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: Self.iso(body)), response)
    }

    /// Dates as ISO 8601 text, as the usage JSON has them.
    private static func iso(_ value: Any) -> Any {
        switch value {
        case let date as Date: ISO8601DateFormatter().string(from: date)
        case let object as [String: Any]: object.mapValues(iso)
        case let list as [Any]: list.map(iso)
        default: value
        }
    }
}

extension Answers: @unchecked Sendable {}

private struct NoCLI: CLIExecutor {
    func locate(_ binary: String) -> String? { nil }
    func execute(binary: String, args: [String], input: String?, timeout: TimeInterval,
                 workingDirectory: URL?, autoResponses: [String: String]) async throws -> CLIResult {
        throw UsageError.cliNotFound(binary)
    }
}

/// A clock whose sleep lasts until the monitor stops: one background tick per test.
private struct Parked: Monitoring.Clock {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: .seconds(86_400)) }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(for: .seconds(86_400)) }
}
