#if os(Linux)
import Foundation
import Glibc

/// The CLIs' own files, read through once before the refresh (design, *The
/// probe*). WSL hands an idle distro's page cache back to Windows within a
/// minute or two, so at the HUD's ten-minute cadence every CLI started from
/// the disk. On the PC, Claude's 317 MB binary and Codex's 217 MB, paged in
/// as they ran, took them past ClaudeBar's 20 s and 15 s on every tick, while
/// a run two minutes after another answered. Read through first, in
/// parallel, they took 4.7 s and 2.5 s, and the tick that followed answered.
public enum Readahead {
    /// What was read: the bytes of each file, by its path with symlinks
    /// followed, and the files the bound stopped before their end.
    public struct Read: Equatable {
        public var bytes: [String: Int] = [:]
        public var unfinished: [String] = []
    }

    /// Each located CLI once, in the order given; a name not found is left out.
    public static func clis(_ names: [String?], locate: (String) -> String?) -> [String] {
        var paths: [String] = []
        for name in names {
            guard let name, let path = locate(name), !paths.contains(path) else { continue }
            paths.append(path)
        }
        return paths
    }

    /// Reads each file to its end, symlinks followed and each file once, on a
    /// thread each, until `within` passes. A file that can't be opened is
    /// left out; one opened without blocking, so a FIFO doesn't hold it.
    public static func read(_ paths: [String], within: Duration) -> Read {
        var files: [String] = []
        for path in paths {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if !files.contains(resolved) { files.append(resolved) }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + within
        let lock = NSLock()
        let box = Box()
        let group = DispatchGroup()
        for file in files {
            DispatchQueue.global().async(group: group) {
                let descriptor = open(file, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { return }
                defer { close(descriptor) }
                let size = 1 << 20
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
                defer { buffer.deallocate() }
                var total = 0
                var finished = false
                while clock.now < deadline {
                    let count = Glibc.read(descriptor, buffer, size)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { finished = true; break }
                    total += count
                }
                lock.withLock {
                    box.read.bytes[file] = total
                    if !finished { box.read.unfinished.append(file) }
                }
            }
        }
        // A read stuck in the kernel past the bound is left to finish on its own.
        _ = group.wait(timeout: .now() + .milliseconds(Int(max(0, (deadline - clock.now) / .milliseconds(1))) + 500))
        return lock.withLock {
            var read = box.read
            read.unfinished.sort()
            return read
        }
    }

    /// What the threads read, under the lock.
    private final class Box: @unchecked Sendable {
        var read = Read()
    }
}
#endif
