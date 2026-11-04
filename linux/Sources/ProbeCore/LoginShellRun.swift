#if os(Linux)
import Foundation
import Glibc

/// How a command run by `run(_:timeout:)` ended.
enum RunEnd: Equatable {
    /// Its exit code, or 128 and the signal that ended it, as a shell reports it.
    case exited(Int32)
    /// The timeout passed, and its process group was killed.
    case timedOut
    /// It couldn't be started: `posix_spawn`'s error.
    case notStarted(Int32)
}

/// Runs a command with `/dev/null` for stdin, stdout and stderr, in a session
/// of its own, and waits for it at most `timeout`.
///
/// A session, not only a process group: `wsl.exe` gives every Linux process a
/// controlling terminal, even one started with no console and every handle
/// redirected. An interactive shell (`-i`) opens `/dev/tty` for job control,
/// and in a background process group of that terminal it stops itself with
/// `SIGTTIN` until its group is in front, which never happens: the import
/// always timed out. A new session has no controlling terminal, so the shell
/// runs without job control. Its leader's process group is its own, so the
/// timeout still ends the whole group.
func run(_ argv: [String], timeout: Duration) -> RunEnd {
    var actions = posix_spawn_file_actions_t()
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for descriptor: Int32 in [0, 1, 2] {
        posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
    }
    var attributes = posix_spawnattr_t()
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, spawnSetSID)

    let arguments = argv.map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, argv[0], &actions, &attributes, arguments, environ)
    guard spawned == 0 else { return .notStarted(spawned) }

    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var status: Int32 = 0
    while true {
        let waited = waitpid(pid, &status, WNOHANG)
        if waited == pid { break }
        if waited == -1, errno != EINTR { return .exited(127) }
        if clock.now >= deadline {
            kill(-pid, SIGKILL)
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            return .timedOut
        }
        usleep(20_000)
    }
    return .exited(status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
}

/// glibc's `POSIX_SPAWN_SETSID` (2.26 and later), which `spawn.h` defines only
/// under `_GNU_SOURCE`, so Swift's `Glibc` doesn't carry it.
private let spawnSetSID: Int16 = 0x80

extension EnvironmentImport {
    /// Asks the login shell once for every name: `env -0` into a file in a
    /// folder only this user can open, made for the run and removed after.
    /// What the shell files print goes to `/dev/null`, and the file is opened
    /// by the command's own redirect after they've run, so nothing they print
    /// or start in the background can write in it.
    public static func importing(names: [String], shell: String?, timeout: Duration = .seconds(3)) -> Outcome {
        guard !names.isEmpty else { return .values([:]) }
        let base = ProcessInfo.processInfo.environment["TMPDIR"].flatMap(safeFolder) ?? "/tmp"
        var template = Array("\(base)/claudebar-env.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else {
            return .failed("couldn't make a folder for the shell's environment: \(String(cString: strerror(errno)))")
        }
        let folder = String(cString: made)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let file = folder + "/env"
        let argv = command(shell: shell, file: file)
        switch run(argv, timeout: timeout) {
        case .timedOut: return .failed("timed out after \(timeout.components.seconds) s")
        case .notStarted(let error): return .failed("couldn't start \(argv[0]): \(String(cString: strerror(error)))")
        case .exited(let code) where code != 0: return .failed("the shell exited with \(code)")
        case .exited: break
        }
        return parse((try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data(), names: names)
    }

    /// `TMPDIR` when it's an absolute path the command can hold unquoted.
    private static func safeFolder(_ path: String) -> String? {
        let trimmed = MountTable.trimmed(path)
        guard trimmed.hasPrefix("/"), trimmed != "/",
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "/._-".unicodeScalars.contains($0)) })
        else { return nil }
        return trimmed
    }
}
#endif
