import DataSources
import Foundation
import Testing
@testable import ProbeCore

/// WSL appends Windows' `PATH`; the probe drops what's on a drive before it
/// looks for a CLI.
@Suite
struct PathRuleTests {
    @Test
    func `should drop every PATH entry under a drive and keep the rest in order`() throws {
        let rule = DriveRule.table(MountTable(mountinfo: try fixture("mountinfo-ubuntu.txt")))
        let path = "/home/me/.local/bin:/mnt/c/Users/me/AppData/Roaming/npm:/usr/bin:/mnt/cache/bin:/mnt/c/Program Files/nodejs/"

        #expect(PathRule.withoutDrives(path, rule) == "/home/me/.local/bin:/usr/bin:/mnt/cache/bin")
    }

    @Test
    func `should keep everything with no drive mounts`() throws {
        let rule = DriveRule.table(MountTable(mountinfo: try fixture("mountinfo-none.txt")))
        let path = "/home/me/.local/bin:/mnt/c/Users/me/AppData/Roaming/npm:/usr/bin"

        #expect(PathRule.withoutDrives(path, rule) == path)
    }
}

#if os(Linux)
/// The design's case, through ClaudeBar's own locator: a Windows npm shim on a
/// drive before a Linux `codex`. The locator reads the process's `PATH`, and
/// changing it here would change it under every test running beside this one
/// (a shell started then couldn't find `env`), so each lookup runs in a child
/// of this test binary started with its own `PATH`.
@Suite
struct PathRuleLocatorTests {
    static let childVariable = "PROBE_LOCATE_IN_CHILD"

    @Test
    func `should find the Linux codex, not the shim on a drive before it`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("probe-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let drive = folder.appendingPathComponent("win/c"), shims = drive.appendingPathComponent("npm")
        let linux = folder.appendingPathComponent("linuxbin")
        for (place, text) in [(shims, "#!/bin/sh\necho windows\n"), (linux, "#!/bin/sh\necho linux\n")] {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            let file = place.appendingPathComponent("codex")
            try writeProgram(text, to: file)
        }
        let mountinfo = "140 88 0:72 / \(drive.path) rw,noatime - 9p C:\\134 rw,aname=drvfs;path=C:\\;uid=1000\n"
        let rule = DriveRule.table(MountTable(mountinfo: mountinfo))
        let path = "\(shims.path):\(linux.path)"

        #expect(try located("codex", path: path) == shims.appendingPathComponent("codex").path)
        #expect(try located("codex", path: PathRule.withoutDrives(path, rule)) == linux.appendingPathComponent("codex").path)
    }

    /// Where `DataSources.locate` finds `cli` in a process whose `PATH` is `path`:
    /// this test binary again, running only the lookup below.
    private func located(_ cli: String, path: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--testing-library", "swift-testing", "--filter", "lookup for the test beside it"]
        process.environment = ["PATH": path, "HOME": "/nonexistent", Self.childVariable: cli]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("located: ") }, "the child printed: \(text)")
        let found = String(line.dropFirst("located: ".count))
        return found == "-" ? nil : found
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment[childVariable] != nil, "runs only in the child the test above starts"))
    func `lookup for the test beside it`() {
        let cli = ProcessInfo.processInfo.environment[Self.childVariable]!
        print("located: \(DataSources.locate(cli) ?? "-")")
    }
}
#endif
