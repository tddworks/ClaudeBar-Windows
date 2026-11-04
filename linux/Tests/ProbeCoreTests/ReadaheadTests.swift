#if os(Linux)
import Foundation
import Testing
@testable import ProbeCore

/// The CLIs' files read through before the refresh, so they start from the
/// page cache, not the disk (design, *The probe*).
@Suite
struct ReadaheadTests {
    @Test
    func `should read each file to its end once, through a symlink, and skip one that isn't there`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("readahead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = folder.appendingPathComponent("claude-2.1.317")
        try Data(repeating: 7, count: 3 * 1_048_576 + 5).write(to: big)
        let link = folder.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)
        let small = folder.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: small)

        let read = Readahead.read([link.path, big.path, small.path, folder.appendingPathComponent("gone").path], within: .seconds(10))

        #expect(read.bytes == [big.resolvingSymlinksInPath().path: 3 * 1_048_576 + 5, small.resolvingSymlinksInPath().path: 10])
        #expect(read.unfinished.isEmpty)
    }

    @Test
    func `should stop at the bound, and say which file it didn't finish`() {
        let clock = ContinuousClock()
        let started = clock.now

        let read = Readahead.read(["/dev/zero"], within: .milliseconds(200))

        #expect(clock.now - started < .seconds(3))
        #expect(read.unfinished == ["/dev/zero"])
        #expect((read.bytes["/dev/zero"] ?? 0) > 0)
    }

    @Test
    func `should take each located CLI once, in order, and none that isn't found`() {
        let found = ["claude": "/home/u/.local/bin/claude", "codex": "/home/u/.local/bin/codex", "omp": "/home/u/.bun/bin/omp"]

        let clis = Readahead.clis(["codex", nil, "claude", "kiro-cli", "codex", "omp"], locate: { found[$0] })

        #expect(clis == ["/home/u/.local/bin/codex", "/home/u/.local/bin/claude", "/home/u/.bun/bin/omp"])
    }
}
#endif
