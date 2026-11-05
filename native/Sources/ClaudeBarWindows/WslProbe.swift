import ClaudeBarShared
import Foundation
import Providers
import WinSDK

/// Why a probe run gave no reading: the text a person reads.
public struct WslFailure: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// One probe run, as the app and (from phase 2) the uploader start it.
public protocol WslProbing: Sendable {
    func run(distro: String, logsOnly: Bool) async -> Result<ProbeReading, WslFailure>
}

/// The process boundary, so the tests can stand in for `wsl.exe`.
public protocol WslProcesses: Sendable {
    /// Runs to the end, or nil past `timeout` (the process then ended).
    func run(_ executable: URL, _ arguments: [String], timeout: Duration) -> WslOutput?
    func start(_ executable: URL, _ arguments: [String]) throws -> any WslRunning
}

public protocol WslRunning: Sendable {
    /// Waits for it to exit, or nil past `timeout`, still running.
    func wait(_ timeout: Duration) -> WslOutput?
    func terminate()
}

public struct WslOutput: Equatable, Sendable {
    public let stdout: Data
    public let stderr: String
    public let exit: Int32
    public init(stdout: Data, stderr: String, exit: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exit = exit
    }
}

/// `claudebar-probe` in one distro, through `wsl.exe` (design, *The probe*
/// and *Running it*).
///
/// A run holds its distro's named mutex, which the app and the uploader
/// share, so one distro runs one probe at a time. A Windows mutex belongs to
/// the thread that took it, and an `async` function can resume on another, so
/// the whole run happens on a `Thread` of its own, with blocking waits, and
/// releases the mutex there.
public final class WslProbe: WslProbing, @unchecked Sendable {
    /// `claudebar-probe` beside the running exe: `linux\x64\claudebar-probe`.
    public static var bundled: URL {
        executableFolder.appendingPathComponent("linux", isDirectory: true)
            .appendingPathComponent("x64", isDirectory: true).appendingPathComponent("claudebar-probe")
    }

    /// `%LOCALAPPDATA%\ClaudeBar\wsl`, for the roots files.
    public static var folder: URL {
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        return local.appendingPathComponent("ClaudeBar", isDirectory: true).appendingPathComponent("wsl", isDirectory: true)
    }

    /// `%SystemRoot%\System32\wsl.exe`.
    public static var systemWsl: URL {
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("System32", isDirectory: true)
            .appendingPathComponent("wsl.exe")
    }

    /// The folder of the process's own exe (`ClaudeBar.exe`, or the uploader
    /// beside it), not of this DLL's host's working folder.
    static var executableFolder: URL {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        let path = String(decoding: buffer.prefix(length), as: UTF16.self)
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    private let probe: URL
    private let folder: URL
    private let deadline: Int
    private let wsl: URL
    private let processes: any WslProcesses
    private let answerWindow: Duration
    private let lock = NSLock()
    /// Each distro's Linux paths of the probe and the roots folder, asked once per start.
    private var linuxPaths: [String: (probe: String, folder: String)] = [:]

    /// The mutex is waited for this long: a run takes at most two `wslpath`
    /// (the first in a distro since the app started), the deadline
    /// (`ProbeTiming.deadline`, 90 s), the answer window, then the running
    /// list and `--end`, each step at most `stepTimeout`.
    static let mutexWait: DWORD = 240_000
    /// Each `wslpath`, list and `--end` gets this long.
    static let stepTimeout: Duration = .seconds(15)

    public init(probe: URL = WslProbe.bundled, folder: URL = WslProbe.folder, deadline: Int = ProbeTiming.deadline,
                wsl: URL = WslProbe.systemWsl,
                processes: any WslProcesses = SystemWslProcesses(), answerWindow: Duration = .seconds(90)) {
        self.probe = probe
        self.folder = folder
        self.deadline = deadline
        self.wsl = wsl
        self.processes = processes
        self.answerWindow = answerWindow
    }

    public func run(distro: String, logsOnly: Bool) async -> Result<ProbeReading, WslFailure> {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: self.runHoldingMutex(distro: distro, logsOnly: logsOnly)) }
            thread.name = "ClaudeBar WSL \(distro)"
            thread.start()
        }
    }

    /// On the run's own thread: takes the distro's mutex, runs, releases it.
    private func runHoldingMutex(distro: String, logsOnly: Bool) -> Result<ProbeReading, WslFailure> {
        let name = WslCommand.mutexName(distro)
        guard let mutex = name.withCString(encodedAs: UTF16.self, { CreateMutexW(nil, false, $0) }) else {
            return .failure(couldNotRun(distro, "its lock couldn't be made (error \(GetLastError()))"))
        }
        defer { CloseHandle(mutex) }
        let wait = WaitForSingleObject(mutex, Self.mutexWait)
        // WAIT_OBJECT_0, or WAIT_ABANDONED (0x80): a process that died holding it hands it over.
        guard wait == WAIT_OBJECT_0 || wait == 0x80 else {
            return .failure(WslFailure("ClaudeBar is still reading \(distro) from another run"))
        }
        defer { ReleaseMutex(mutex) }
        return runInDistro(distro, logsOnly: logsOnly)
    }

    private func runInDistro(_ distro: String, logsOnly: Bool) -> Result<ProbeReading, WslFailure> {
        guard FileManager.default.fileExists(atPath: probe.path) else {
            return .failure(WslFailure("This build of ClaudeBar has no WSL reader"))
        }
        let paths: (probe: String, folder: String)
        switch linuxPaths(in: distro) {
        case .success(let found): paths = found
        case .failure(let failure): return .failure(failure)
        }

        let run = WslCommand.newRun()
        let roots: URL
        do {
            let windows = WslWindowsRoots.make(distro: distro, definitions: ProviderCatalog().detect(),
                                               homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                                               environment: { ProcessInfo.processInfo.environment[$0] })
            roots = try WslWindowsRoots.write(windows, run: run, in: folder)
        } catch {
            return .failure(couldNotRun(distro, "its folders couldn't be written (\(error.localizedDescription))"))
        }
        defer { try? FileManager.default.removeItem(at: roots) }

        let arguments = WslCommand.probe(distro: distro, probe: paths.probe, run: run,
                                         windowsRoots: paths.folder + "/" + roots.lastPathComponent,
                                         deadline: deadline, logsOnly: logsOnly)
        let running: any WslRunning
        do {
            running = try processes.start(wsl, arguments)
        } catch {
            return .failure(couldNotRun(distro, error.localizedDescription))
        }
        let window = Duration.seconds(deadline) + answerWindow
        guard let output = running.wait(window) else {
            // Checking and launching aren't one step: a distro that stopped in
            // between would be started again, and `--end` would find nothing.
            let listed = processes.run(wsl, WslCommand.list(runningOnly: true), timeout: Self.stepTimeout)
            if let listed, listed.exit == 0, WslCommand.distros(in: listed.stdout).contains(distro) {
                _ = processes.run(wsl, WslCommand.end(distro: distro, probe: paths.probe, target: run), timeout: Self.stepTimeout)
            }
            running.terminate()
            return .failure(couldNotRun(distro, "no answer in \(window.components.seconds) s"))
        }
        guard output.exit == 0 else { return .failure(couldNotRun(distro, Self.reason(output))) }
        guard let reading = try? ProbeReading.decoder().decode(ProbeReading.self, from: output.stdout),
              reading.version == ClientVersion.version else {
            return .failure(WslFailure("ClaudeBar's WSL reader is from another version"))
        }
        return .success(reading)
    }

    /// The probe's and the roots folder's Linux paths in `distro`, asked once per start.
    private func linuxPaths(in distro: String) -> Result<(probe: String, folder: String), WslFailure> {
        lock.lock()
        let known = linuxPaths[distro]
        lock.unlock()
        if let known { return .success(known) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var found: [String] = []
        for url in [probe, folder] {
            let windowsPath = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
            guard let output = processes.run(wsl, WslCommand.wslpath(distro: distro, path: windowsPath), timeout: Self.stepTimeout) else {
                return .failure(couldNotRun(distro, "wslpath didn't answer in \(Self.stepTimeout.components.seconds) s"))
            }
            let linux = WslCommand.text(in: output.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.exit == 0, linux.hasPrefix("/") else { return .failure(couldNotRun(distro, Self.reason(output))) }
            found.append(linux.hasSuffix("/") && linux.count > 1 ? String(linux.dropLast()) : linux)
        }
        let paths = (probe: found[0], folder: found[1])
        lock.lock()
        linuxPaths[distro] = paths
        lock.unlock()
        return .success(paths)
    }

    private func couldNotRun(_ distro: String, _ why: String) -> WslFailure {
        WslFailure("ClaudeBar couldn't run in \(distro): \(why)")
    }

    /// What went wrong, from a run that didn't exit 0: its error's line, else
    /// what it wrote, else its exit code.
    static func reason(_ output: WslOutput) -> String {
        let line = WslCommand.failureLine(output.stderr)
        if !line.isEmpty { return line }
        let written = WslCommand.failureLine(WslCommand.text(in: output.stdout))
        return written.isEmpty ? "wsl.exe exited \(output.exit)" : written
    }
}

/// `WslProcesses` over `CreateProcessW`: `wsl.exe` with no window of its own
/// (`CREATE_NO_WINDOW`; Foundation's `Process` passes no such flag, so from
/// the app, which has no console, `wsl.exe` would get a console window for
/// the whole run), stdin from `NUL`, and only its three standard handles
/// inherited. stdout and stderr are each read to their end on a thread of
/// its own, so a full pipe never stops it.
public struct SystemWslProcesses: WslProcesses {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], timeout: Duration) -> WslOutput? {
        guard let running = try? start(executable, arguments) else { return nil }
        guard let output = running.wait(timeout) else {
            running.terminate()
            return nil
        }
        return output
    }

    public func start(_ executable: URL, _ arguments: [String]) throws -> any WslRunning {
        try SystemWslRunning(executable, arguments)
    }
}

final class SystemWslRunning: WslRunning, @unchecked Sendable {
    private let process: HANDLE
    /// Our ends of the child's stdout and stderr, each read and then closed
    /// by its own reader thread, which reaches them through `self`.
    private let outRead: HANDLE
    private let errRead: HANDLE
    private let readers = DispatchGroup()
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    /// How long the pipes get to drain once the process has exited.
    static let drain: TimeInterval = 5

    init(_ executable: URL, _ arguments: [String]) throws {
        var inheritable = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                                              lpSecurityDescriptor: nil, bInheritHandle: true)
        var outRead: HANDLE?, outWrite: HANDLE?, errRead: HANDLE?, errWrite: HANDLE?
        guard CreatePipe(&outRead, &outWrite, &inheritable, 0) else { throw Self.failure("CreatePipe") }
        guard CreatePipe(&errRead, &errWrite, &inheritable, 0) else {
            CloseHandle(outRead); CloseHandle(outWrite)
            throw Self.failure("CreatePipe")
        }
        let nul = "NUL".withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &inheritable, DWORD(OPEN_EXISTING), 0, nil)
        }
        // The child's ends close in this process once it holds its own copies.
        defer { CloseHandle(outWrite); CloseHandle(errWrite); CloseHandle(nul) }
        guard let outRead, let errRead, let nul, nul != HANDLE(bitPattern: -1) else {
            CloseHandle(outRead); CloseHandle(errRead)
            throw Self.failure("opening NUL")
        }
        // Our ends stay here.
        SetHandleInformation(outRead, DWORD(HANDLE_FLAG_INHERIT), 0)
        SetHandleInformation(errRead, DWORD(HANDLE_FLAG_INHERIT), 0)

        do {
            process = try Self.create(executable, arguments, stdin: nul, stdout: outWrite, stderr: errWrite)
        } catch {
            CloseHandle(outRead); CloseHandle(errRead)
            throw error
        }
        self.outRead = outRead
        self.errRead = errRead
        startReading(error: false)
        startReading(error: true)
    }

    deinit { CloseHandle(process) }

    private static func create(_ executable: URL, _ arguments: [String], stdin: HANDLE, stdout: HANDLE?, stderr: HANDLE?) throws -> HANDLE {
        var size: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { storage.deallocate() }
        let attributes = LPPROC_THREAD_ATTRIBUTE_LIST(storage)
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &size) else { throw failure("InitializeProcThreadAttributeList") }
        defer { DeleteProcThreadAttributeList(attributes) }
        // PROC_THREAD_ATTRIBUTE_HANDLE_LIST, a macro the SDK module doesn't carry: the
        // child inherits these three and none of the app's other inheritable handles.
        let handleList: DWORD_PTR = 0x0002_0002
        var handles: [HANDLE?] = [stdin, stdout, stderr]
        let listed = handles.withUnsafeMutableBytes {
            UpdateProcThreadAttribute(attributes, 0, handleList, $0.baseAddress, SIZE_T($0.count), nil, nil)
        }
        guard listed else { throw failure("UpdateProcThreadAttribute") }

        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.StartupInfo.hStdInput = stdin
        startup.StartupInfo.hStdOutput = stdout
        startup.StartupInfo.hStdError = stderr
        startup.lpAttributeList = attributes

        let path = executable.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? executable.path
        var commandLine = Array(WslCommand.commandLine(path, arguments).utf16) + [0]
        let flags = DWORD(EXTENDED_STARTUPINFO_PRESENT) | DWORD(CREATE_NO_WINDOW)
        var information = PROCESS_INFORMATION()
        let created = withUnsafeMutablePointer(to: &startup) { pointer in
            pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) {
                CreateProcessW(nil, &commandLine, nil, nil, true, flags, nil, nil, $0, &information)
            }
        }
        guard created, let process = information.hProcess else { throw failure("CreateProcessW") }
        CloseHandle(information.hThread)
        return process
    }

    private static func failure(_ step: String) -> WslFailure {
        WslFailure("\(step) failed (error \(GetLastError()))")
    }

    private func startReading(error: Bool) {
        readers.enter()
        Thread.detachNewThread { [self] in self.drain(error: error) }
    }

    /// Reads one pipe to its end, then closes it.
    private func drain(error: Bool) {
        let handle = error ? errRead : outRead
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var count: DWORD = 0
        while ReadFile(handle, &buffer, DWORD(buffer.count), &count, nil), count > 0 {
            let chunk = Data(buffer.prefix(Int(count)))
            lock.withLock { if error { stderr += chunk } else { stdout += chunk } }
        }
        CloseHandle(handle)
        readers.leave()
    }

    func wait(_ timeout: Duration) -> WslOutput? {
        let (seconds, attoseconds) = timeout.components
        let milliseconds = min(Double(seconds) * 1000 + Double(attoseconds) / 1e15, Double(DWORD.max - 1))
        guard WaitForSingleObject(process, DWORD(milliseconds)) == WAIT_OBJECT_0 else { return nil }
        // Whatever it wrote before it ended; a pipe a grandchild still holds isn't waited for long.
        _ = readers.wait(timeout: .now() + Self.drain)
        var code: DWORD = 0
        GetExitCodeProcess(process, &code)
        return lock.withLock { WslOutput(stdout: stdout, stderr: WslCommand.text(in: stderr), exit: Int32(bitPattern: code)) }
    }

    func terminate() {
        TerminateProcess(process, 1)
    }
}
