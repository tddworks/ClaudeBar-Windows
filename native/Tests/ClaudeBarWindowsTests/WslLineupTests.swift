import DataSources
import Foundation
import Providers
import Quotas
import Testing
@testable import ClaudeBarShared

/// Each distro's tools in the HUD's lineup, after this PC's
/// (docs/plans/2026-11-03-wsl-design.md, The HUD, Limits and Settings):
/// under ids that name the distro, without what Linux can't read, and kept
/// with `notRunning` while the distro is stopped.
@MainActor
@Suite
struct WslLineupTests {
    private let at1400 = Date(timeIntervalSince1970: 1_762_232_400)
    private var at1405: Date { at1400.addingTimeInterval(300) }

    // MARK: - Fixtures

    /// Claude's session limit, read at 14:00 unless said.
    private func claude(_ percent: Double = 62, at: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(providerId: "claude", quotas: [UsageQuota(percentRemaining: percent, quotaType: .session, providerId: "claude")],
                      capturedAt: at ?? at1400)
    }

    private var claude: UsageSnapshot { claude() }

    /// omp reading one Claude account, its group "Claude · work".
    private var ompWork: UsageSnapshot {
        UsageSnapshot(providerId: "omp", quotas: [UsageQuota(percentRemaining: 50, quotaType: .timeLimit("Claude 5h · work"),
                                                             providerId: "omp", group: "Claude · work")],
                      capturedAt: at1400)
    }

    /// Every login's look, before the answer keeps those it shows.
    private let lineup = [
        HudMonitor.Look(id: "claude", name: "Claude", light: "#D97757", dark: "#E08A6D"),
        HudMonitor.Look(id: "codex", name: "Codex", light: "#10A37F", dark: "#10A37F"),
        HudMonitor.Look(id: "antigravity", name: "Antigravity", light: "#4285F4", dark: "#4285F4"),
        HudMonitor.Look(id: "omp", name: "Oh My Pi", light: "#299E61", dark: "#4DD98C"),
    ]

    /// An answer as `HudMonitor` makes one: the reading, its problems spread
    /// over its groups, and the looks of what it shows.
    private func answer(_ snapshots: [UsageSnapshot], problems: [HudMonitor.Problem] = []) -> HudMonitor.Answer {
        let reading = HudReading(snapshots: snapshots, policy: .absolute)
        let shown = Set(snapshots.map(\.providerId) + problems.map(\.id))
        return HudMonitor.Answer(reading: reading, readAt: snapshots.map(\.capturedAt).max(),
                                 problems: HudMonitor.spread(problems, over: reading),
                                 looks: HudMonitor.looks(lineup.filter { shown.contains($0.id) }, for: reading,
                                                         definitions: Array(ProviderFactory.builtInDefinitions.values)))
    }

    /// This PC: Claude, healthy, at 14:00.
    private var windows: HudMonitor.Answer { answer([claude]) }

    private func probe(_ answer: HudMonitor.Answer?, timedOut: Bool = false) -> ProbeReading {
        ProbeReading(version: ClientVersion.version, hud: answer, days: [], tools: [], skipped: [], timeZone: "Asia/Seoul",
                     timedOut: timedOut, environmentImport: .init(state: .imported, names: [], reason: nil), diagnostics: [])
    }

    private func running(_ name: String, answer snapshots: [UsageSnapshot], problems: [HudMonitor.Problem] = [],
                         reading: [String] = [], timedOut: Bool = false) -> WslDistro {
        let problems = problems + reading.map { HudMonitor.Problem(id: $0, kind: "reading", message: "") }
        return WslDistro(name: name, running: true, reading: probe(answer(snapshots, problems: problems), timedOut: timedOut),
                         answeredAt: at1405, failure: nil)
    }

    private func stopped(_ name: String, kept snapshots: [UsageSnapshot]?, problems: [HudMonitor.Problem] = []) -> WslDistro {
        WslDistro(name: name, running: false, reading: snapshots.map { probe(answer($0, problems: problems)) },
                  answeredAt: snapshots == nil ? nil : at1400, failure: nil)
    }

    /// What ClaudeBar's `Unavailable` says on Linux of a source it has no connection for.
    private var noLocalServer: String {
        DataSourceError(.fetch, .executionFailed("Reading a local server isn't available on Linux yet.")).errorDescription!
    }

    /// Ubuntu: Claude; Codex not set up; Antigravity, a local server Linux can't read.
    private var ubuntu: WslDistro {
        running("Ubuntu-26.04", answer: [claude], problems: [
            HudMonitor.Problem(id: "codex", kind: "notSetUp", message: "Install Codex"),
            HudMonitor.Problem(id: "antigravity", kind: "failed", message: noLocalServer),
        ])
    }

    /// Debian: Claude.
    private var debian: WslDistro { running("Debian", answer: [claude]) }

    // MARK: - Tests

    @Test func `should put a distro's tools after this PC's, under ids prefixed with the distro`() {
        let merged = WslLineup.merge(windows, with: [running("Ubuntu-26.04", answer: [claude, ompWork])])

        #expect(merged.reading.tools.map(\.id) == ["claude", "wsl:Ubuntu-26.04/claude", "wsl:Ubuntu-26.04/omp/Claude · work"])
        #expect(merged.reading.tools.last?.via == "wsl:Ubuntu-26.04/omp")
        #expect(merged.looks.map(\.id) == ["claude", "wsl:Ubuntu-26.04/claude", "wsl:Ubuntu-26.04/omp", "wsl:Ubuntu-26.04/omp/Claude · work"])
    }

    @Test func `should name one distro's tools "· WSL", and with the distro's name when there are two`() {
        #expect(WslLineup.merge(windows, with: [ubuntu]).looks.map(\.name) == ["Claude", "Claude · WSL"])
        #expect(WslLineup.merge(windows, with: [ubuntu, debian]).looks.map(\.name)
                == ["Claude", "Claude · WSL Ubuntu-26.04", "Claude · WSL Debian"])
    }

    @Test func `should leave out notSetUp and a source Linux can't read at all`() {
        let merged = WslLineup.merge(windows, with: [ubuntu])

        #expect(merged.problems.map(\.id).allSatisfy { !$0.hasPrefix("wsl:") })
        #expect(merged.looks.map(\.id) == ["claude", "wsl:Ubuntu-26.04/claude"])
    }

    @Test func `should keep a distro's other problems, renamed`() {
        let signedOut = HudMonitor.Problem(id: "codex", kind: "signedOut", message: "Run codex login")
        let merged = WslLineup.merge(windows, with: [running("Ubuntu-26.04", answer: [claude], problems: [signedOut])])

        #expect(merged.problems == [.init(id: "wsl:Ubuntu-26.04/codex", kind: "signedOut", message: "Run codex login")])
        #expect(merged.looks.map(\.id) == ["claude", "wsl:Ubuntu-26.04/claude", "wsl:Ubuntu-26.04/codex"])
    }

    @Test func `should keep a stopped distro's last numbers, each tool notRunning`() {
        let signedOut = HudMonitor.Problem(id: "codex", kind: "signedOut", message: "Run codex login")
        let merged = WslLineup.merge(windows, with: [stopped("Ubuntu-26.04", kept: [claude], problems: [signedOut])])

        #expect(merged.reading.tools.map(\.id) == ["claude", "wsl:Ubuntu-26.04/claude"])
        #expect(merged.problems == [.init(id: "wsl:Ubuntu-26.04/claude", kind: "notRunning", message: ""),
                                    .init(id: "wsl:Ubuntu-26.04/codex", kind: "notRunning", message: "")])
    }

    @Test func `should say failed on each kept tool when a run fails, and once for the distro with none kept`() {
        let failure = "ClaudeBar couldn't run in Ubuntu-26.04: libcurl.so.4: cannot open shared object file"
        let none = WslDistro(name: "Ubuntu-26.04", running: true, reading: nil, answeredAt: nil, failure: failure)
        let kept = WslDistro(name: "Ubuntu-26.04", running: true, reading: probe(answer([claude, ompWork])), answeredAt: at1400, failure: failure)

        let merged = WslLineup.merge(windows, with: [none])
        #expect(merged.problems.last == .init(id: "wsl:Ubuntu-26.04", kind: "failed", message: failure))
        #expect(merged.looks.last?.id == "wsl:Ubuntu-26.04")
        #expect(merged.looks.last?.name == "WSL Ubuntu-26.04")
        #expect(merged.looks.last?.light == "#8A8A8A")

        let withKept = WslLineup.merge(windows, with: [kept])
        #expect(withKept.reading.tools.map(\.id) == ["claude", "wsl:Ubuntu-26.04/claude", "wsl:Ubuntu-26.04/omp/Claude · work"])
        #expect(withKept.problems == [.init(id: "wsl:Ubuntu-26.04/claude", kind: "failed", message: failure),
                                      .init(id: "wsl:Ubuntu-26.04/omp/Claude · work", kind: "failed", message: failure)])
    }

    @Test func `should say a login still reading at the deadline took too long`() {
        let merged = WslLineup.merge(windows, with: [running("Ubuntu-26.04", answer: [claude], reading: ["codex"], timedOut: true)])

        #expect(merged.problems.contains(.init(id: "wsl:Ubuntu-26.04/codex", kind: "failed", message: "Took too long in WSL")))
        #expect(!merged.problems.contains { $0.kind == "reading" })
    }

    @Test func `should name the worst status over both, and the newest time`() {
        let merged = WslLineup.merge(windows, with: [running("Ubuntu-26.04", answer: [claude(10, at: at1405)])])

        #expect(windows.reading.worst == "healthy")
        #expect(merged.reading.worst == "critical")
        #expect(merged.readAt == at1405)
    }

    @Test func `should leave a stopped distro with nothing kept out`() {
        #expect(WslLineup.merge(windows, with: [stopped("Ubuntu-26.04", kept: nil)]) == windows)
    }

    @Test func `should show a stopped distro as not running even when its last run failed`() {
        let failure = "ClaudeBar couldn't run in Ubuntu-26.04: no answer in 150 s"
        let kept = WslDistro(name: "Ubuntu-26.04", running: false, reading: probe(answer([claude])), answeredAt: at1400, failure: failure)
        let none = WslDistro(name: "Ubuntu-26.04", running: false, reading: nil, answeredAt: nil, failure: failure)

        #expect(WslLineup.merge(windows, with: [kept]).problems == [.init(id: "wsl:Ubuntu-26.04/claude", kind: "notRunning", message: "")])
        #expect(WslLineup.merge(windows, with: [none]) == windows)
    }
}
