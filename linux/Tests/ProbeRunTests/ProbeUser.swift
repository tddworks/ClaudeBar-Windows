#if os(Linux)
import ClaudeBarShared
import Foundation
import Glibc
import ProbeCore

/// A Linux user made for one test, with a home of fixture files, who runs
/// the built `claudebar-probe` as `wsl.exe -e` runs it: as that user, with the
/// marker set by `env`, no shell. ClaudeBar's home on Linux follows
/// `/etc/passwd`, not `$HOME`, so a fixture home is a fixture user.
/// Needs root, to make and delete users.
final class ProbeUser {
    static let isRoot = getuid() == 0

    let name: String
    let home: URL
    let uid: uid_t
    let gid: gid_t

    init() throws {
        name = "cbprobe\(UInt32.random(in: 100_000...999_999))"
        try Self.command(["useradd", "-m", "-s", "/bin/bash", name])
        guard let entry = getpwnam(name) else { throw Failure("no passwd entry for \(name)") }
        uid = entry.pointee.pw_uid
        gid = entry.pointee.pw_gid
        home = URL(fileURLWithPath: String(cString: entry.pointee.pw_dir), isDirectory: true)
    }

    deinit {
        // Anything of the user's still running would stop userdel.
        _ = try? Self.command(["pkill", "-KILL", "-u", name])
        _ = try? Self.command(["userdel", "-r", "-f", name])
    }

    /// The probe beside this test binary: `swift test` builds it.
    static var probe: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("claudebar-probe").path
    }

    /// A run id as the app makes one.
    static func runId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Writes a file in the home, owned by the user; `executable` makes it a program.
    func write(_ path: String, _ text: String, executable: Bool = false) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // O_CLOEXEC: Foundation's write(to:atomically:) opens its file without
        // it, so a child another test starts at that moment would keep the
        // file open for writing, and running it would fail with ETXTBSY.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, executable ? 0o755 : 0o644)
        guard descriptor >= 0 else { throw Failure("couldn't write \(url.path)") }
        let bytes = Array(text.utf8)
        let written = Glibc.write(descriptor, bytes, bytes.count)
        close(descriptor)
        guard written == bytes.count else { throw Failure("couldn't write \(url.path)") }
        try Self.command(["chown", "-R", "\(name):\(name)", home.path])
    }

    func makeFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        try Self.command(["chown", "-R", "\(name):\(name)", home.path])
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) }

    func read(_ path: String) -> String? {
        (try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A roots file in the home, as the app writes one.
    func rootsFile(distro: String = "Test", _ providers: [ProviderRoots] = []) throws -> String {
        let roots = WindowsRoots(version: ClientVersion.version, distro: distro, providers: providers)
        try write("windows-roots.json", String(decoding: try JSONEncoder().encode(roots), as: UTF8.self))
        return home.appendingPathComponent("windows-roots.json").path
    }

    /// This user's home in the form the app's roots file names it.
    func windowsPath(_ path: String, distro: String = "Test") -> String {
        "\\\\wsl.localhost\\\(distro)" + home.appendingPathComponent(path).path.replacingOccurrences(of: "/", with: "\\")
    }

    /// A started probe: its PID is the probe's own (`setpriv` and `env` exec it).
    final class Run {
        let process: Process
        let stdout: URL
        let stderr: URL
        let started = ContinuousClock.now

        init(process: Process, stdout: URL, stderr: URL) {
            self.process = process
            self.stdout = stdout
            self.stderr = stderr
        }

        var pid: pid_t { process.processIdentifier }

        func finish() -> Result {
            process.waitUntilExit()
            let result = Result(status: process.terminationStatus,
                                stdout: (try? Data(contentsOf: stdout)) ?? Data(),
                                stderr: String(decoding: (try? Data(contentsOf: stderr)) ?? Data(), as: UTF8.self),
                                seconds: Self.seconds(ContinuousClock.now - started))
            try? FileManager.default.removeItem(at: stdout)
            try? FileManager.default.removeItem(at: stderr)
            return result
        }

        static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
    }

    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
        let seconds: Double

        func reading() throws -> ProbeReading { try ProbeReading.decoder().decode(ProbeReading.self, from: stdout) }
    }

    /// Starts the probe as this user, with the environment `wsl.exe -e` gives
    /// and, unless `marker` is nil, `CLAUDEBAR_WSL_RUN=<marker>`.
    func start(_ arguments: [String], marker: String?) throws -> Run {
        var environment = ["HOME=\(home.path)", "USER=\(name)", "LOGNAME=\(name)", "SHELL=/bin/bash",
                           "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C.UTF-8"]
        if let marker { environment.append("\(RunMarker.name)=\(marker)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/setpriv")
        process.arguments = ["--reuid=\(uid)", "--regid=\(gid)", "--init-groups", "--",
                             "/usr/bin/env", "-i"] + environment + [Self.probe] + arguments
        process.currentDirectoryURL = home
        let folder = FileManager.default.temporaryDirectory
        let stdout = folder.appendingPathComponent("probe-out-\(UUID().uuidString)")
        let stderr = folder.appendingPathComponent("probe-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: stdout)
        process.standardError = try FileHandle(forWritingTo: stderr)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return Run(process: process, stdout: stdout, stderr: stderr)
    }

    func run(_ arguments: [String], marker: String?) throws -> Result {
        try start(arguments, marker: marker).finish()
    }

    /// Whether a PID still answers `kill -0`, waiting up to 5 s for it to be
    /// reaped: a zombie still answers, until PID 1 (`--init`) reaps it.
    static func isGone(_ pid: pid_t) -> Bool {
        for _ in 0..<50 {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            usleep(100_000)
        }
        return false
    }

    /// Waits up to `seconds` for a file the fixture writes.
    func waitFor(_ path: String, seconds: Double) -> Bool {
        let clock = ContinuousClock(), end = clock.now + .milliseconds(Int(seconds * 1000))
        while clock.now < end {
            if exists(path) { return true }
            usleep(50_000)
        }
        return exists(path)
    }

    /// For a failure's message: the user's processes now, and the end of
    /// ClaudeBar's log in the home.
    func whatRan() -> String {
        let processes = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap { pid_t($0) }
            .filter { pid in (try? FileManager.default.attributesOfItem(atPath: "/proc/\(pid)"))?[.ownerAccountID] as? UInt == UInt(uid) }
            .map { pid in "\(pid): " + String(decoding: readProcFile("/proc/\(pid)/cmdline") ?? Data(), as: UTF8.self)
                .replacingOccurrences(of: "\0", with: " ") }
        let log = read(".local/share/ClaudeBar/Logs/ClaudeBar.log")?.split(separator: "\n").suffix(15).joined(separator: "\n") ?? "no log"
        return "processes:\n\(processes.joined(separator: "\n"))\nlog:\n\(log)"
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @discardableResult
    static func command(_ argv: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Their own PATH, not the test process's.
        process.arguments = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"] + argv
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("\(argv.joined(separator: " ")) exited with \(process.terminationStatus)") }
        return process.terminationStatus
    }
}

/// Fixture records, dated today and the days before, in the container's zone.
enum Records {
    static func day(_ daysAgo: Int) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -daysAgo, to: calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!)!
    }

    static func timestamp(_ daysAgo: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: day(daysAgo))
    }

    static func label(_ daysAgo: Int) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day(daysAgo))
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// A Claude Code assistant record of `tokens` input tokens.
    static func claude(_ daysAgo: Int, tokens: Int, id: String) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp(daysAgo))","requestId":"req-\(id)","cwd":"/tmp","message":{"id":"msg-\(id)","model":"claude-sonnet-4-5","usage":{"input_tokens":\(tokens),"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    /// A Codex token count of `tokens` input tokens.
    static func codex(_ daysAgo: Int, tokens: Int) -> String {
        """
        {"timestamp":"\(timestamp(daysAgo))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(tokens + 5),"input_tokens":\(tokens),"cached_input_tokens":0,"output_tokens":5},"last_token_usage":{"input_tokens":\(tokens),"cached_input_tokens":0,"output_tokens":5}}}}
        """
    }

    /// The path of today's Codex session folder.
    static func codexSession(_ folder: String) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day(0))
        return String(format: "%@/sessions/%04d/%02d/%02d/rollout-1.jsonl", folder, parts.year!, parts.month!, parts.day!)
    }
}
#endif
