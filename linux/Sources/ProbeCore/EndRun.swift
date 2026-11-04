#if os(Linux)
import Foundation
import Glibc

/// `--end` (design, *The marker*): every process whose `/proc/<pid>/environ`
/// carries the run's marker gets `SIGKILL`, and the table is read again
/// every 100 ms until none is left or 10 s pass. A process of another user
/// can't be read, so only the probe's own user's are ended.
public enum EndRun {
    /// True when no process carrying the marker is left, `sparing` aside.
    @discardableResult
    public static func end(_ target: RunMarker.Target, sparing spared: pid_t, within limit: Duration = .seconds(10)) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while true {
            let marked = processes(carrying: target).filter { $0 != spared }
            if marked.isEmpty { return true }
            for pid in marked { kill(pid, SIGKILL) }
            if clock.now >= deadline { return false }
            usleep(100_000)
        }
    }

    /// The processes carrying the marker now. A zombie's environ is empty,
    /// so it carries none: it's dead, waiting for its parent to reap it.
    public static func processes(carrying target: RunMarker.Target) -> [pid_t] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return entries.compactMap { pid_t($0) }.filter { pid in
            guard let environ = readProcFile("/proc/\(pid)/environ") else { return false }
            return RunMarker.matches(environ, target)
        }
    }
}

/// A `/proc` file's bytes, read to its end: its size says 0. Nil when it
/// can't be opened (another user's process, or one that's gone).
public func readProcFile(_ path: String) -> Data? {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 { data.append(buffer, count: count); continue }
        if count == -1, errno == EINTR { continue }
        return count == 0 ? data : nil
    }
}
#endif
