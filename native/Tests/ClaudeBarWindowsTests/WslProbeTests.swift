import ClaudeBarShared
import Foundation
import Testing
@testable import ClaudeBarWindows

/// One probe run in a distro, with `wsl.exe` stood in for (design, *Running
/// it*): the distro's mutex, the Linux paths asked once, the roots file
/// for the run alone, and the kill order when no answer comes.
@Suite
struct WslProbeTests {
    /// A distro of the test's own, so its mutex is no real one's.
    private let distro = "ClaudeBarTest-\(UUID().uuidString.prefix(8))"
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cbw-wsl-\(UUID().uuidString)", isDirectory: true)
    private var probeFile: URL { folder.appendingPathComponent("linux/x64/claudebar-probe") }
    private var rootsFolder: URL { folder.appendingPathComponent("roots", isDirectory: true) }

    /// The checked-in sample both sides read, of this client's version.
    static func sample() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/wsl-probe.json")
        return try Data(contentsOf: url)
    }

    private func makeProbeFile() throws {
        try FileManager.default.createDirectory(at: probeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ELF".utf8).write(to: probeFile)
    }

    private func probe(_ wsl: FakeWsl, deadline: Int = 60, answerWindow: Duration = .seconds(90)) -> WslProbe {
        WslProbe(probe: probeFile, folder: rootsFolder, deadline: deadline, wsl: URL(fileURLWithPath: #"C:\fake\wsl.exe"#),
                 processes: wsl, answerWindow: answerWindow)
    }

    @Test func `should read a good answer, asking wslpath once, the run marked and its roots file gone afterwards`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeProbeFile()
        let wsl = FakeWsl(rootsFolder: rootsFolder, answer: .output(WslOutput(stdout: try Self.sample(), stderr: "", exit: 0)))
        let probe = probe(wsl)

        let first = await probe.run(distro: distro, logsOnly: false)
        let second = await probe.run(distro: distro, logsOnly: false)

        let expected = try ProbeReading.decoder().decode(ProbeReading.self, from: Self.sample())
        #expect(first == .success(expected))
        #expect(second == .success(expected))
        let calls = wsl.calls
        #expect(calls.filter { $0.contains("wslpath") }.count == 2)
        let lines = calls.filter { $0.hasPrefix("start ") }
        #expect(lines.count == 2)
        let run = try #require(wsl.runs.first)
        #expect(run.count == 32 && run.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(lines[0] == "start -d \(distro) -e env CLAUDEBAR_WSL_RUN=\(run) /mnt/c/cb/linux/x64/claudebar-probe --json --windows-roots /mnt/c/cb/roots/windows-roots-\(run).json --deadline 60")
        #expect(wsl.rootsSeen == [true, true])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rootsFolder.path)) ?? []).isEmpty)
    }

    /// A CLI that never answers is stopped at its timeout plus the start
    /// allowance, and the data source it falls back to starts only then
    /// (Codex's JSON-RPC, 15 s, then its terminal, 20 s). The refresh grows
    /// by the allowance, so that fallback keeps the 45 s it had in 60 s.
    @Test func `should give the refresh 60 s and the CLIs' start allowance, and wait that long for a run in the mutex`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeProbeFile()
        let wsl = FakeWsl(rootsFolder: rootsFolder, answer: .output(WslOutput(stdout: try Self.sample(), stderr: "", exit: 0)))

        _ = await WslProbe(probe: probeFile, folder: rootsFolder, wsl: URL(fileURLWithPath: #"C:\fake\wsl.exe"#), processes: wsl)
            .run(distro: distro, logsOnly: false)

        let line = try #require(wsl.calls.first { $0.hasPrefix("start ") })
        #expect(line.hasSuffix(" --deadline 90"))
        // A run at its longest: two `wslpath`, the deadline, the 90 s answer
        // window, then the running list and `--end`.
        let step = Int(WslProbe.stepTimeout.components.seconds)
        #expect(Int(WslProbe.mutexWait) >= (2 * step + 90 + 90 + 2 * step) * 1000)
    }

    @Test func `should say the probe's line when it finds no marker`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeProbeFile()
        let wsl = FakeWsl(rootsFolder: rootsFolder, answer: .output(WslOutput(stdout: Data(), stderr: "claudebar-probe: no run marker\n", exit: 3)))

        let result = await probe(wsl).run(distro: distro, logsOnly: false)

        #expect(result == .failure(WslFailure("ClaudeBar couldn't run in \(distro): claudebar-probe: no run marker")))
    }

    @Test func `should refuse another version's answer`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeProbeFile()
        var json = try #require(try JSONSerialization.jsonObject(with: Self.sample()) as? [String: Any])
        json["version"] = "0.0.1"
        let wsl = FakeWsl(rootsFolder: rootsFolder,
                          answer: .output(WslOutput(stdout: try JSONSerialization.data(withJSONObject: json), stderr: "", exit: 0)))

        let result = await probe(wsl).run(distro: distro, logsOnly: false)

        #expect(result == .failure(WslFailure("ClaudeBar's WSL reader is from another version")))
    }

    @Test func `should say there's no reader when the build has none`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let wsl = FakeWsl(rootsFolder: rootsFolder, answer: .never)

        let result = await probe(wsl).run(distro: distro, logsOnly: false)

        #expect(result == .failure(WslFailure("This build of ClaudeBar has no WSL reader")))
        #expect(wsl.calls.isEmpty)
    }

    @Test func `should say wslpath's error when the distro can't run it`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeProbeFile()
        let wsl = FakeWsl(rootsFolder: rootsFolder, answer: .never,
                          wslpath: WslOutput(stdout: Data(), stderr: "wsl: Failed to start the systemd user session for 'me'.\nwslpath: bad path\n", exit: 1))

        let result = await probe(wsl).run(distro: distro, logsOnly: false)

        #expect(result == .failure(WslFailure("ClaudeBar couldn't run in \(distro): wsl: Failed to start the systemd user session for 'me'.")))
        #expect(!wsl.calls.contains { $0.hasPrefix("start ") })
    }

    @Test func `should end the run, then wsl.exe, when no answer comes and the distro still runs`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeProbeFile()
        let wsl = FakeWsl(rootsFolder: rootsFolder, answer: .never, running: [distro])

        let result = await probe(wsl, deadline: 0, answerWindow: .zero).run(distro: distro, logsOnly: false)

        #expect(result == .failure(WslFailure("ClaudeBar couldn't run in \(distro): no answer in 0 s")))
        let run = try #require(wsl.runs.first)
        #expect(Array(wsl.calls.drop { !$0.hasPrefix("start ") }.dropFirst())
                == ["-l --running -q", "-d \(distro) -e /mnt/c/cb/linux/x64/claudebar-probe --end \(run)", "terminate"])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rootsFolder.path)) ?? []).isEmpty)
    }

    @Test func `should end only wsl.exe when the distro stopped meanwhile`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeProbeFile()
        let wsl = FakeWsl(rootsFolder: rootsFolder, answer: .never, running: ["Another"])

        _ = await probe(wsl, deadline: 0, answerWindow: .zero).run(distro: distro, logsOnly: false)

        #expect(Array(wsl.calls.drop { !$0.hasPrefix("start ") }.dropFirst()) == ["-l --running -q", "terminate"])
    }

    @Test func `should run one probe at a time in a distro, the app's and the uploader's alike`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeProbeFile()
        let wsl = FakeWsl(rootsFolder: rootsFolder, answer: .output(WslOutput(stdout: try Self.sample(), stderr: "", exit: 0)),
                          answerAfter: 0.5)
        let app = probe(wsl), uploader = probe(wsl)

        async let first = app.run(distro: distro, logsOnly: false)
        async let second = uploader.run(distro: distro, logsOnly: true)
        let results = await [first, second]

        #expect(results.allSatisfy { if case .success = $0 { true } else { false } })
        // Each run's probe line is followed by its own answer before the other's starts.
        let events = wsl.calls.filter { $0.hasPrefix("start ") || $0.hasPrefix("waited ") }
        let runs = wsl.runs
        #expect(events.count == 4 && runs.count == 2)
        #expect(events[0].contains(runs[0]) && events[1] == "waited \(runs[0])")
        #expect(events[2].contains(runs[1]) && events[3] == "waited \(runs[1])")
    }
}

@Suite
struct SystemWslProcessesTests {
    private let cmd = URL(fileURLWithPath: #"C:\Windows\System32\cmd.exe"#)
    private let powershell = URL(fileURLWithPath: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#)

    @Test func `should run a command to its end`() throws {
        let output = try #require(SystemWslProcesses().run(cmd, ["/c", "echo hi"], timeout: .seconds(30)))

        #expect(String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
        #expect(output.exit == 0)
    }

    @Test func `should give up waiting on a command still running, and end it`() throws {
        let running = try SystemWslProcesses().start(powershell, ["-NoProfile", "-Command", "Start-Sleep 600"])

        #expect(running.wait(.seconds(1)) == nil)
        running.terminate()
        #expect(running.wait(.seconds(30)) != nil)
    }
}

/// `wsl.exe`, answering by argument and recording each call in order.
final class FakeWsl: WslProcesses, @unchecked Sendable {
    enum Answer: Sendable { case output(WslOutput), never }

    private let lock = NSLock()
    private let rootsFolder: URL
    private let answer: Answer
    private let answerAfter: TimeInterval
    private let running: [String]
    private let wslpath: WslOutput?
    private var recorded: [String] = []
    private var started: [String] = []
    private var seen: [Bool] = []

    init(rootsFolder: URL, answer: Answer, answerAfter: TimeInterval = 0, running: [String] = [], wslpath: WslOutput? = nil) {
        self.rootsFolder = rootsFolder
        self.answer = answer
        self.answerAfter = answerAfter
        self.running = running
        self.wslpath = wslpath
    }

    var calls: [String] { lock.withLock { recorded } }
    /// Each probe line's run id, in the order they started.
    var runs: [String] { lock.withLock { started } }
    /// Whether the run's roots file was there when its probe line started.
    var rootsSeen: [Bool] { lock.withLock { seen } }

    func record(_ call: String) { lock.withLock { recorded.append(call) } }

    func run(_ executable: URL, _ arguments: [String], timeout: Duration) -> WslOutput? {
        record(arguments.joined(separator: " "))
        if arguments.contains("wslpath") {
            if let wslpath { return wslpath }
            let linux = arguments.last!.hasSuffix("claudebar-probe") ? "/mnt/c/cb/linux/x64/claudebar-probe\n" : "/mnt/c/cb/roots/\n"
            return WslOutput(stdout: Data(linux.utf8), stderr: "", exit: 0)
        }
        if arguments == ["-l", "--running", "-q"] {
            return WslOutput(stdout: running.map { $0 + "\r\n" }.joined().data(using: .utf16LittleEndian)!, stderr: "", exit: 0)
        }
        return WslOutput(stdout: Data(), stderr: "", exit: 0)
    }

    func start(_ executable: URL, _ arguments: [String]) throws -> any WslRunning {
        let run = arguments.first { $0.hasPrefix("CLAUDEBAR_WSL_RUN=") }.map { String($0.dropFirst("CLAUDEBAR_WSL_RUN=".count)) } ?? ""
        let exists = FileManager.default.fileExists(atPath: rootsFolder.appendingPathComponent("windows-roots-\(run).json").path)
        lock.withLock {
            recorded.append("start " + arguments.joined(separator: " "))
            started.append(run)
            seen.append(exists)
        }
        return FakeRunning(wsl: self, run: run, answer: answer, after: answerAfter)
    }
}

final class FakeRunning: WslRunning, @unchecked Sendable {
    private let wsl: FakeWsl
    private let run: String
    private let answer: FakeWsl.Answer
    private let after: TimeInterval
    private let ended = DispatchSemaphore(value: 0)

    init(wsl: FakeWsl, run: String, answer: FakeWsl.Answer, after: TimeInterval) {
        self.wsl = wsl
        self.run = run
        self.answer = answer
        self.after = after
    }

    func wait(_ timeout: Duration) -> WslOutput? {
        switch answer {
        case .output(let output):
            Thread.sleep(forTimeInterval: after)
            wsl.record("waited \(run)")
            return output
        case .never:
            let (seconds, attoseconds) = timeout.components
            _ = ended.wait(timeout: .now() + Double(seconds) + Double(attoseconds) / 1e18)
            return nil
        }
    }

    func terminate() {
        wsl.record("terminate")
        ended.signal()
    }
}
