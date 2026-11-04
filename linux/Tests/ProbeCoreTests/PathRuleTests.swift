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
/// drive before a Linux `codex`. It sets the process's `PATH`, so it runs alone.
@Suite(.serialized)
struct PathRuleLocatorTests {
    @Test
    func `should find the Linux codex, not the shim on a drive before it`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("probe-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let drive = folder.appendingPathComponent("win/c"), shims = drive.appendingPathComponent("npm")
        let linux = folder.appendingPathComponent("linuxbin")
        for (place, text) in [(shims, "#!/bin/sh\necho windows\n"), (linux, "#!/bin/sh\necho linux\n")] {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            let file = place.appendingPathComponent("codex")
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let mountinfo = "140 88 0:72 / \(drive.path) rw,noatime - 9p C:\\134 rw,aname=drvfs;path=C:\\;uid=1000\n"
        let rule = DriveRule.table(MountTable(mountinfo: mountinfo))
        let saved = ProcessInfo.processInfo.environment["PATH"]
        defer { if let saved { setenv("PATH", saved, 1) } else { unsetenv("PATH") } }
        let path = "\(shims.path):\(linux.path)"
        setenv("PATH", path, 1)
        #expect(DataSources.locate("codex") == shims.appendingPathComponent("codex").path)

        setenv("PATH", PathRule.withoutDrives(path, rule), 1)

        #expect(DataSources.locate("codex") == linux.appendingPathComponent("codex").path)
    }
}
#endif
