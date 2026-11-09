import Foundation
import Testing
@testable import ClaudeBarShared
@testable import ClaudeBarWindows

/// The distros on the HUD (design, *The HUD, Limits and Settings*): which are
/// probed, what each shows, and the reply's `wsl`, with the probe and
/// `wsl.exe`'s lists stood in for.
@Suite @MainActor
struct WslHudTests {
    private let reading: ProbeReading
    private let windows: HudMonitor.Answer

    init() throws {
        reading = try ProbeReading.decoder().decode(ProbeReading.self, from: WslProbeTests.sample())
        windows = HudMonitor.Answer(reading: HudReading(tools: [], worst: "healthy"), readAt: nil, problems: [], looks: [])
    }

    private func hud(_ probe: FakeProbing, all: [String]? = ["Ubuntu-26.04", "Debian", "docker-desktop"],
                     running: [String] = ["Ubuntu-26.04", "docker-desktop"]) -> WslHud {
        WslHud(probe: probe, list: { $0 ? running : all }, interval: .seconds(3600))
    }

    /// The ids the answer shows for a distro, in its tools and its problems.
    private func shown(_ answer: HudMonitor.Answer, in distro: String) -> [String] {
        (answer.reading.tools.map(\.id) + answer.problems.map(\.id)).filter { $0.hasPrefix("wsl:\(distro)/") }
    }

    @Test func `should probe each running distro once, not Docker's, nor one switched off`() async {
        let probe = FakeProbing([:], reading: reading)
        let wsl = hud(probe, running: ["Ubuntu-26.04", "Debian", "docker-desktop"])
        wsl.configure(["Debian": WslHud.Kept(on: false, reading: reading, answeredAt: Date())])

        _ = wsl.answer(merging: windows)
        await wsl.settled()
        let answer = wsl.answer(merging: windows)

        #expect(probe.calls == ["Ubuntu-26.04"])
        #expect(!shown(answer, in: "Ubuntu-26.04").isEmpty)
        #expect(shown(answer, in: "Debian").isEmpty)
    }

    @Test func `should show a stopped distro's kept numbers as not running, and not probe it`() async {
        let probe = FakeProbing([:], reading: reading)
        let wsl = hud(probe, running: [])
        wsl.configure(["Debian": WslHud.Kept(on: true, reading: reading, answeredAt: Date(timeIntervalSince1970: 1_762_230_000))])

        _ = wsl.answer(merging: windows)
        await wsl.settled()
        let answer = wsl.answer(merging: windows)

        #expect(probe.calls.isEmpty)
        let problems = answer.problems.filter { $0.id.hasPrefix("wsl:Debian/") }
        #expect(!problems.isEmpty && problems.allSatisfy { $0.kind == "notRunning" })
    }

    @Test func `should keep the reading when a later run fails, and say why`() async throws {
        let probe = FakeProbing([:], reading: reading)
        let wsl = hud(probe)
        _ = wsl.answer(merging: windows)
        await wsl.settled()

        probe.fail("Ubuntu-26.04", with: "ClaudeBar couldn't run in Ubuntu-26.04: no answer in 150 s")
        wsl.refresh()
        await wsl.settled()

        let row = try #require(try distros(wsl).first { $0["name"] as? String == "Ubuntu-26.04" })
        #expect(row["error"] as? String == "ClaudeBar couldn't run in Ubuntu-26.04: no answer in 150 s")
        #expect(try decoded(row["reading"]) == reading)
        #expect(!shown(wsl.answer(merging: windows), in: "Ubuntu-26.04").isEmpty)
    }

    @Test func `should read app.json's wsl, a switch kept when its reading is from another shape`() throws {
        let sample = String(decoding: try WslProbeTests.sample(), as: UTF8.self)

        let kept = WslHud.kept(fromJSON: #"{"Debian": {"on": true, "answeredAt": 1762230000, "reading": "# + sample
                               + #"}, "Ubuntu-26.04": {"on": false, "reading": {"version": 7}}, "Arch": {}}"#)

        #expect(kept == [
            "Debian": WslHud.Kept(on: true, reading: reading, answeredAt: Date(timeIntervalSince1970: 1_762_230_000)),
            "Ubuntu-26.04": WslHud.Kept(on: false, reading: nil, answeredAt: nil),
            "Arch": WslHud.Kept(on: nil, reading: nil, answeredAt: nil),
        ])
        #expect(WslHud.kept(fromJSON: "").isEmpty)
    }

    @Test func `should list each distro in the reply with what's kept for it`() async throws {
        let sample = String(decoding: try WslProbeTests.sample(), as: UTF8.self)
        let wsl = hud(FakeProbing([:], reading: reading), running: [])
        wsl.configure(WslHud.kept(fromJSON: #"{"Debian": {"on": true, "answeredAt": 1762230000, "reading": "# + sample + "}}"))

        _ = wsl.answer(merging: windows)
        await wsl.settled()
        let json = try wsl.json()

        #expect(json["installed"] as? Bool == true)
        let rows = try distros(wsl)
        #expect(rows.map { $0["name"] as? String } == ["Ubuntu-26.04", "Debian"])
        let debian = rows[1]
        #expect(debian["running"] as? Bool == false && debian["on"] as? Bool == true && debian["probing"] as? Bool == false)
        #expect((debian["answeredAt"] as? NSNumber)?.doubleValue == 1_762_230_000)
        #expect(try decoded(debian["reading"]) == reading)
        #expect(debian["error"] is NSNull)
        #expect(rows[0]["on"] is NSNull && rows[0]["reading"] is NSNull)
    }

    /// The two refreshes' lists answer after 500 ms, as they can on a busy
    /// runner: the test must not count on them landing while the run is held.
    @Test func `should start no second run in a distro while one is in flight`() async throws {
        let probe = FakeProbing([:], reading: reading, holding: true)
        let lists = ListCounter()
        let wsl = WslHud(probe: probe, list: { running in
            if await lists.count(running) > 2 { try? await Task.sleep(for: .milliseconds(500)) }
            return running ? ["Ubuntu-26.04", "docker-desktop"] : ["Ubuntu-26.04", "Debian", "docker-desktop"]
        }, interval: .seconds(3600))

        _ = wsl.answer(merging: windows)
        await probe.started(1)
        wsl.refresh()
        wsl.refresh()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(try distros(wsl).first { $0["name"] as? String == "Ubuntu-26.04" }?["probing"] as? Bool == true)
        probe.release()
        await wsl.settled()

        #expect(probe.calls == ["Ubuntu-26.04"])
    }

    @Test func `should answer this PC's alone when WSL isn't there`() async throws {
        let probe = FakeProbing([:], reading: reading)
        let wsl = WslHud(probe: probe, list: { _ in nil }, interval: .seconds(3600))

        _ = wsl.answer(merging: windows)
        await wsl.settled()

        #expect(try wsl.json()["installed"] as? Bool == false)
        #expect(wsl.answer(merging: windows) == windows)
        #expect(probe.calls.isEmpty)
    }

    @Test func `should list the running distros again when the last list is over 30 s old`() async {
        let clock = Clock()
        let counter = ListCounter()
        let wsl = WslHud(probe: FakeProbing([:], reading: reading), list: { running in
            await counter.count(running)
            return running ? [] : ["Ubuntu-26.04"]
        }, interval: .seconds(3600), now: { clock.now })

        _ = wsl.answer(merging: windows)
        await wsl.settled()
        _ = wsl.answer(merging: windows)
        await wsl.settled()
        #expect(await counter.running == 1)

        clock.now += 31
        _ = wsl.answer(merging: windows)
        await wsl.settled()

        #expect(await counter.running == 2)
        #expect(await counter.all == 1)
    }

    @Test func `should probe a running distro as soon as its switch turns on`() async {
        let probe = FakeProbing([:], reading: reading)
        let wsl = hud(probe)
        wsl.configure(["Ubuntu-26.04": WslHud.Kept(on: false, reading: reading, answeredAt: Date())])
        _ = wsl.answer(merging: windows)
        await wsl.settled()
        #expect(probe.calls.isEmpty)

        wsl.configure(["Ubuntu-26.04": WslHud.Kept(on: true, reading: reading, answeredAt: Date())])
        await wsl.settled()

        #expect(probe.calls == ["Ubuntu-26.04"])
    }

    /// As on the PC: the distro started after the last refresh, and its switch,
    /// never set, showed off in Settings because no reading had found a tool.
    @Test func `should probe a running distro as soon as its switch is first set on`() async {
        let running = RunningList([])
        let probe = FakeProbing([:], reading: reading)
        let wsl = WslHud(probe: probe, list: { $0 ? running.value : ["Ubuntu-26.04"] }, interval: .seconds(3600))
        _ = wsl.answer(merging: windows)
        await wsl.settled()
        #expect(probe.calls.isEmpty)

        running.value = ["Ubuntu-26.04"]
        wsl.configure(["Ubuntu-26.04": WslHud.Kept(on: true, reading: nil, answeredAt: nil)])
        await wsl.settled()

        #expect(probe.calls == ["Ubuntu-26.04"])
    }

    @Test func `should not probe again when the switches come back unchanged`() async {
        let probe = FakeProbing([:], reading: reading)
        let wsl = hud(probe)
        wsl.configure(["Ubuntu-26.04": WslHud.Kept(on: true, reading: reading, answeredAt: Date())])
        _ = wsl.answer(merging: windows)
        await wsl.settled()
        #expect(probe.calls == ["Ubuntu-26.04"])

        wsl.configure(["Ubuntu-26.04": WslHud.Kept(on: true, reading: reading, answeredAt: Date())])
        await wsl.settled()

        #expect(probe.calls == ["Ubuntu-26.04"])
    }

    @Test func `should keep the running distros when the running list fails, and probe nothing on it`() async {
        let clock = Clock()
        let running = RunningList(["Ubuntu-26.04"])
        let probe = FakeProbing([:], reading: reading)
        let wsl = WslHud(probe: probe, list: { $0 ? running.value : ["Ubuntu-26.04"] }, interval: .seconds(3600), now: { clock.now })
        _ = wsl.answer(merging: windows)
        await wsl.settled()

        running.value = nil
        wsl.refresh()
        await wsl.settled()
        clock.now += 31
        _ = wsl.answer(merging: windows)
        await wsl.settled()
        let answer = wsl.answer(merging: windows)

        #expect(probe.calls == ["Ubuntu-26.04"])
        #expect(!shown(answer, in: "Ubuntu-26.04").isEmpty)
        #expect(!answer.problems.contains { $0.kind == "notRunning" })
    }

    @Test func `should end every run in each running distro before an uninstall, not in Docker's`() {
        let wsl = FakeWsl(rootsFolder: FileManager.default.temporaryDirectory, answer: .never, running: ["Ubuntu-26.04", "docker-desktop"])

        let swept = WslHud.endAll(processes: wsl, wsl: URL(fileURLWithPath: #"C:\fake\wsl.exe"#),
                                  probe: URL(fileURLWithPath: #"C:\cb\linux\x64\claudebar-probe"#), budget: 20)

        #expect(swept == 1)
        #expect(wsl.calls.count == 3)
        #expect(wsl.calls.first == "-l --running -q")
        #expect(wsl.calls.dropFirst().first?.hasPrefix("-d Ubuntu-26.04 -e wslpath -u ") == true)
        #expect(wsl.calls.last == "-d Ubuntu-26.04 -e /mnt/c/cb/linux/x64/claudebar-probe --end all")
    }

    @Test func `should say -1 when wsl.exe can't list the distros, and run nothing more`() {
        let wsl = FailingList()

        #expect(WslHud.endAll(processes: wsl, wsl: URL(fileURLWithPath: #"C:\fake\wsl.exe"#),
                              probe: URL(fileURLWithPath: #"C:\cb\claudebar-probe"#), budget: 20) == -1)
        #expect(wsl.count == 1)
    }

    private func distros(_ wsl: WslHud) throws -> [[String: Any]] {
        try #require(wsl.json()["distros"] as? [[String: Any]])
    }

    private func decoded(_ value: Any?) throws -> ProbeReading? {
        guard let value, !(value is NSNull) else { return nil }
        return try ProbeReading.decoder().decode(ProbeReading.self, from: JSONSerialization.data(withJSONObject: value))
    }
}

/// The probe, answering each distro with the reading unless told to fail,
/// counting the runs, and optionally holding each until released.
final class FakeProbing: WslProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: String]
    private let reading: ProbeReading
    private let holding: Bool
    private var recorded: [String] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(_ failures: [String: String], reading: ProbeReading, holding: Bool = false) {
        self.failures = failures
        self.reading = reading
        self.holding = holding
    }

    var calls: [String] { lock.withLock { recorded } }

    func fail(_ distro: String, with message: String) { lock.withLock { failures[distro] = message } }

    func release() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    /// Returns once `count` runs have started.
    func started(_ count: Int) async {
        while calls.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func run(distro: String, logsOnly: Bool) async -> Result<ProbeReading, WslFailure> {
        lock.withLock { recorded.append(distro) }
        if holding {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    if released { return true }
                    waiting.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }
        if let failure = lock.withLock({ failures[distro] }) { return .failure(WslFailure(failure)) }
        return .success(reading)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_762_230_000)
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// `wsl.exe -l --running -q`'s answer, changed by the test; nil when it fails.
private final class RunningList: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [String]?
    init(_ current: [String]?) { self.current = current }
    var value: [String]? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

private actor ListCounter {
    var running = 0
    var all = 0
    /// Counts one list and returns how many were asked so far, of both kinds.
    @discardableResult func count(_ runningOnly: Bool) -> Int {
        if runningOnly { running += 1 } else { all += 1 }
        return running + all
    }
}

/// `wsl.exe` when WSL isn't installed: every list fails.
private final class FailingList: WslProcesses, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }

    func run(_ executable: URL, _ arguments: [String], timeout: Duration) -> WslOutput? {
        lock.withLock { calls += 1 }
        return WslOutput(stdout: Data(), stderr: "", exit: -1)
    }

    func start(_ executable: URL, _ arguments: [String]) throws -> any WslRunning {
        throw WslFailure("no WSL")
    }
}
