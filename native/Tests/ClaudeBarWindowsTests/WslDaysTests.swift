import Foundation
import Leaderboard
import Quotas
import Testing
@testable import ClaudeBarShared
@testable import ClaudeBarWindows

/// The distros' days in the Leaderboard's token logs
/// (docs/plans/2026-11-03-wsl-design.md, The Leaderboard (phase 2)): the kept
/// days as they count now, after a `--logs-only` run in each running distro
/// that's on when fresh. The probe, the lists and the switches are stood in
/// for; every kept day is in a folder of the test's own.
@Suite @MainActor
struct WslDaysTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cbw-wsldays-\(UUID().uuidString)", isDirectory: true)
    private var kept: WslKeptDays { WslKeptDays(folder: folder.appendingPathComponent("days", isDirectory: true)) }
    private let calendar = WslKeptDaysTests.calendar("Asia/Seoul")
    private let lines = Lines()
    private nonisolated static let seoul = TimeZone(identifier: "Asia/Seoul")!
    private nonisolated static let now = WslKeptDaysTests.noon("2026-11-12", WslKeptDaysTests.calendar("Asia/Seoul"))

    private var window: DateRange { WslKeptDaysTests.window(endingOn: "2026-11-12", calendar) }

    private func days(fresh: Bool, probe: RecordingProbe, running: [String]? = [], lists: Counter = Counter(),
                      switches: [String: Bool] = [:], zone: TimeZone = seoul, windows: [ProviderRoots] = []) -> WslDays {
        WslDays(fresh: fresh, probe: probe, kept: kept,
                list: { _ in await lists.add(); return running },
                switches: { switches }, zone: { zone }, now: { Self.now }, windows: { windows },
                log: { [lines] in lines.add($0) })
    }

    private func summed(_ logins: [LoginDays], providers: Set<String> = ["claude"]) -> [DailyTokens] {
        DailyTokens.summed(logins, providers: providers, calendar: calendar)
    }

    private static func entry(_ distro: String, _ input: Int, provider: String = "claude", root: String? = nil,
                              at hour: Int = 10) -> WslKeptDays.Entry {
        WslKeptDaysTests.entry(distro, at: WslKeptDaysTests.at(hour), roots: root.map { [(provider, $0)] } ?? [],
                               days: [WslKeptDaysTests.day(provider, "2026-11-11", input)])
    }

    @Test func `should give the kept days back, running nothing and listing nothing, when not fresh`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try kept.save(Self.entry("Ubuntu-26.04", 7))
        let probe = RecordingProbe(kept: kept)
        let lists = Counter()

        let logins = await days(fresh: false, probe: probe, running: ["Ubuntu-26.04"], lists: lists).days(in: window, calendar: calendar)

        #expect(summed(logins) == [WslKeptDaysTests.day("claude", "2026-11-11", 7)])
        #expect(probe.calls.isEmpty)
        #expect(await lists.count == 0)
    }

    @Test func `should read each running distro that's on, logs only, before giving the kept days, a switched-off one's frozen`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try kept.save(Self.entry("Debian", 5))
        let probe = RecordingProbe(kept: kept, answers: ["Ubuntu-26.04": .save(Self.entry("Ubuntu-26.04", 7))])

        let logins = await days(fresh: true, probe: probe, running: ["Ubuntu-26.04", "Debian", "docker-desktop"],
                                switches: ["Debian": false]).days(in: window, calendar: calendar)

        #expect(probe.calls == ["Ubuntu-26.04 logsOnly"])
        #expect(summed(logins) == [WslKeptDaysTests.day("claude", "2026-11-11", 12)])
    }

    @Test func `should give a failed distro's kept days, and say why it couldn't be read`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try kept.save(Self.entry("Ubuntu-26.04", 7))
        let probe = RecordingProbe(kept: kept, answers: ["Ubuntu-26.04": .fail("ClaudeBar couldn't run in Ubuntu-26.04: no answer in 90 s")])

        let logins = await days(fresh: true, probe: probe, running: ["Ubuntu-26.04"]).days(in: window, calendar: calendar)

        #expect(summed(logins) == [WslKeptDaysTests.day("claude", "2026-11-11", 7)])
        #expect(lines.all == ["Leaderboard: WSL Ubuntu-26.04: ClaudeBar couldn't run in Ubuntu-26.04: no answer in 90 s; its kept days go"])
    }

    @Test func `should run nothing when the running list fails, and give the kept days`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try kept.save(Self.entry("Ubuntu-26.04", 7))
        let probe = RecordingProbe(kept: kept)

        let logins = await days(fresh: true, probe: probe, running: nil).days(in: window, calendar: calendar)

        #expect(probe.calls.isEmpty)
        #expect(summed(logins) == [WslKeptDaysTests.day("claude", "2026-11-11", 7)])
    }

    @Test func `should give a removed distro's kept days`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try kept.save(Self.entry("Gone", 7))
        let probe = RecordingProbe(kept: kept)

        let logins = await days(fresh: true, probe: probe, running: ["Ubuntu-26.04"]).days(in: window, calendar: calendar)

        #expect(probe.calls == ["Ubuntu-26.04 logsOnly"])
        #expect(summed(logins) == [WslKeptDaysTests.day("claude", "2026-11-11", 7)])
    }

    @Test func `should leave out days kept in another zone than Windows' now, and all of them when it has no name`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try kept.save(Self.entry("Ubuntu-26.04", 7))
        let probe = RecordingProbe(kept: kept)

        let angeles = await days(fresh: false, probe: probe, zone: TimeZone(identifier: "America/Los_Angeles")!)
            .days(in: window, calendar: calendar)
        let unnamed = await days(fresh: false, probe: probe, zone: TimeZone(secondsFromGMT: 19_800)!).days(in: window, calendar: calendar)

        #expect(summed(angeles).isEmpty)
        #expect(summed(unnamed).isEmpty)
        #expect(lines.all == [
            "Leaderboard: WSL Ubuntu-26.04: kept days left out: counted in Asia/Seoul, and Windows' zone is America/Los_Angeles now",
            "Leaderboard: WSL Ubuntu-26.04: kept days left out: counted in Asia/Seoul, and Windows' zone is none now",
        ])
    }

    @Test func `should leave out a provider's kept days whose root this PC reads now`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = #"C:\Users\me\wsl-claude\projects"#
        try kept.save(WslKeptDaysTests.entry("Ubuntu-26.04", roots: [("claude", root)],
                                             days: [WslKeptDaysTests.day("claude", "2026-11-11", 1),
                                                    WslKeptDaysTests.day("codex", "2026-11-11", 2)]))
        let probe = RecordingProbe(kept: kept)

        let logins = await days(fresh: false, probe: probe,
                                windows: [ProviderRoots(provider: "claude", credentials: [], logs: [root])])
            .days(in: window, calendar: calendar)

        #expect(summed(logins, providers: ["claude", "codex"]) == [WslKeptDaysTests.day("codex", "2026-11-11", 2)])
        #expect(lines.all == [#"Leaderboard: WSL Ubuntu-26.04: kept claude days left out: Windows reads C:\Users\me\wsl-claude\projects now, and they came from C:\Users\me\wsl-claude\projects"#])
    }

    @Test func `should count the latest reading of a folder two distros read`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let shared = #"D:\shared\.claude\projects"#
        try kept.save(Self.entry("Debian", 120, root: shared, at: 10))
        try kept.save(Self.entry("Ubuntu-26.04", 30, root: shared, at: 11))
        let probe = RecordingProbe(kept: kept)

        let logins = await days(fresh: false, probe: probe).days(in: window, calendar: calendar)

        #expect(summed(logins) == [WslKeptDaysTests.day("claude", "2026-11-11", 30)])
        #expect(lines.all == [#"Leaderboard: WSL Debian: kept claude days left out: D:\shared\.claude\projects is read by Ubuntu-26.04 too, and its reading is the latest"#])
    }

    @Test func `should read each distro's switch from app.json, and none from a file that's missing or broken`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appendingPathComponent("app.json")
        try Data(#"{"theme": "dark", "wsl": {"Debian": {"on": false}, "Ubuntu-26.04": {"answeredAt": 1}}}"#.utf8).write(to: app)
        let broken = folder.appendingPathComponent("broken.json")
        try Data("{".utf8).write(to: broken)

        #expect(WslDays.switches(appJSON: app) == ["Debian": false])
        #expect(WslDays.switches(appJSON: broken).isEmpty)
        #expect(WslDays.switches(appJSON: folder.appendingPathComponent("missing.json")).isEmpty)
    }

    @Test func `should add a distro's kept day to this PC's, and list this PC's providers`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try kept.save(WslKeptDaysTests.entry("Ubuntu-26.04", days: [WslKeptDaysTests.day("claude", "2026-11-11", 1),
                                                                    WslKeptDaysTests.day("omp", "2026-11-11", 3)]))
        let pc = Provider(id: "claude", name: "Claude", light: "#D97757", dark: "#D97757")
        let logs = DeviceTokenLogs(windows: PCLogs([WslKeptDaysTests.pc("2026-11-11", 100, calendar)], providers: ["claude", "codex"]),
                                   providers: [pc], wsl: days(fresh: false, probe: RecordingProbe(kept: kept)),
                                   calendar: { [calendar] in calendar })

        let logins = await logs.days(in: window)

        #expect(summed(logins) == [WslKeptDaysTests.day("claude", "2026-11-11", 101)])
        #expect(logs.providersWithLogs == ["claude", "codex", "omp"])
        #expect(logs.providers == [pc])
    }
}

private typealias Provider = ProviderTokenLogs.Provider

/// The probe in a distro, recording each run: it keeps the distro's answer
/// through `kept` as `WslProbe` does, answers without keeping (a refused
/// zone), or fails, as a stopped distro does.
final class RecordingProbe: WslProbing, @unchecked Sendable {
    enum Answer: Sendable {
        case save(WslKeptDays.Entry)
        case refuse
        case fail(String)
    }

    private let lock = NSLock()
    private let kept: WslKeptDays
    private var answers: [String: Answer]
    private var recorded: [String] = []

    init(kept: WslKeptDays, answers: [String: Answer] = [:]) {
        self.kept = kept
        self.answers = answers
    }

    /// Each run, `<distro> logsOnly` or `<distro> json`, in the order they started.
    var calls: [String] { lock.withLock { recorded } }

    func answer(_ distro: String, _ answer: Answer?) { lock.withLock { answers[distro] = answer } }

    func run(distro: String, logsOnly: Bool) async -> Result<ProbeReading, WslFailure> {
        let answer = lock.withLock { () -> Answer? in
            recorded.append("\(distro) \(logsOnly ? "logsOnly" : "json")")
            return answers[distro]
        }
        switch answer {
        case .save(let entry):
            do { try kept.save(entry) } catch { return .failure(WslFailure("couldn't keep: \(error)")) }
            return .success(Self.reading(days: entry.days, zone: entry.timeZone, roots: entry.logRoots))
        case .refuse:
            return .success(Self.reading(days: nil, zone: "Asia/Seoul", roots: []))
        case .fail(let message):
            return .failure(WslFailure(message))
        case nil:
            return .failure(WslFailure("ClaudeBar couldn't run in \(distro): it isn't running"))
        }
    }

    private static func reading(days: [DailyTokens]?, zone: String, roots: [ProbeReading.LogRoot]) -> ProbeReading {
        ProbeReading(version: ClientVersion.version, hud: nil, days: days, tools: [], skipped: [], logRoots: roots, timeZone: zone,
                     timedOut: false, environmentImport: .init(state: .imported, names: [], reason: nil), diagnostics: [])
    }
}

/// Lines a test's code logged, in order.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
}

actor Counter {
    private(set) var count = 0
    func add() { count += 1 }
}

/// This PC's days, by hand.
@MainActor
private final class PCLogs: TokenLogs {
    private let logins: [LoginDays]
    let providersWithLogs: Set<String>
    init(_ logins: [LoginDays], providers: Set<String>) {
        self.logins = logins
        providersWithLogs = providers
    }
    func days(in range: DateRange) async -> [LoginDays] { logins.map { $0.within(range) } }
}
