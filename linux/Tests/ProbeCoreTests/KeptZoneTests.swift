import Foundation
import Testing
@testable import ProbeCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The zone the distro's kept days were counted in (design, *Kept days carry
/// no zone*): the ledger's pages go when the zone changes, the scans stay.
@Suite
struct KeptZoneTests {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent("kept-zone-\(UUID().uuidString)")
    private var ledger: URL { home.appendingPathComponent(".claudebar/usage-history") }
    private var zoneFile: URL { home.appendingPathComponent(".local/share/ClaudeBar/wsl-zone") }

    /// Two pages and a scan, as ClaudeBar leaves them.
    private func makeLedger() throws {
        try FileManager.default.createDirectory(at: ledger.appendingPathComponent("scans"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: ledger.appendingPathComponent("claude.json"))
        try Data("{}".utf8).write(to: ledger.appendingPathComponent("codex.json"))
        try Data("{}".utf8).write(to: ledger.appendingPathComponent("scans/claude-Asia_Seoul.json"))
    }

    private func recordZone(_ zone: String) throws {
        try FileManager.default.createDirectory(at: zoneFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(zone)\n".utf8).write(to: zoneFile)
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: ledger.appendingPathComponent(path).path) }
    private var recorded: String? {
        (try? String(contentsOf: zoneFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test
    func `should keep the pages when no run recorded a zone and the distro's own is the one counted in`() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeLedger()

        #expect(try KeptZone(home: home).prepare(counting: "Asia/Seoul", own: "Asia/Seoul") == false)

        #expect(exists("claude.json") && exists("codex.json"))
        #expect(recorded == "Asia/Seoul")
    }

    @Test
    func `should remove the pages and keep the scans when the distro's own zone isn't the one counted in`() throws {
        // A PC updated straight to phase 2: the pages were counted in the distro's own zone.
        defer { try? FileManager.default.removeItem(at: home) }
        try makeLedger()

        #expect(try KeptZone(home: home).prepare(counting: "America/Los_Angeles", own: "Asia/Seoul") == true)

        #expect(!exists("claude.json") && !exists("codex.json"))
        #expect(exists("scans/claude-Asia_Seoul.json"))
        #expect(recorded == "America/Los_Angeles")
    }

    @Test
    func `should take an unknown own zone as another`() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeLedger()

        #expect(try KeptZone(home: home).prepare(counting: "Asia/Seoul", own: nil) == true)

        #expect(!exists("claude.json"))
        #expect(recorded == "Asia/Seoul")
    }

    @Test
    func `should remove nothing when the recorded zone is the one counted in`() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeLedger()
        try recordZone("America/Los_Angeles")

        #expect(try KeptZone(home: home).prepare(counting: "America/Los_Angeles", own: "Asia/Seoul") == false)

        #expect(exists("claude.json") && exists("codex.json"))
        #expect(recorded == "America/Los_Angeles")
    }

    @Test
    func `should go by the recorded zone, not the distro's own`() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeLedger()
        try recordZone("America/Los_Angeles")

        #expect(try KeptZone(home: home).prepare(counting: "Asia/Seoul", own: "Asia/Seoul") == true)

        #expect(!exists("claude.json"))
        #expect(recorded == "Asia/Seoul")
    }

    @Test
    func `should record the zone, and say nothing started over, when there's no ledger yet`() throws {
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(try KeptZone(home: home).prepare(counting: "Asia/Seoul", own: "Europe/Kyiv") == false)

        #expect(recorded == "Asia/Seoul")
    }

    @Test(.enabled(if: getuid() != 0, "root removes a page from a read-only folder"))
    func `should say which page it couldn't remove, and record nothing`() throws {
        defer {
            chmod(ledger.path, 0o755)
            try? FileManager.default.removeItem(at: home)
        }
        try makeLedger()
        try recordZone("Asia/Seoul")
        chmod(ledger.path, 0o555)

        let page = ledger.appendingPathComponent("claude.json").path
        let codex = ledger.appendingPathComponent("codex.json").path
        #expect {
            try KeptZone(home: home).prepare(counting: "America/Los_Angeles", own: "Asia/Seoul")
        } throws: { error in
            guard let failure = error as? KeptZone.Failure else { return false }
            return (failure.path == page || failure.path == codex) && failure.reason == "Permission denied"
                && failure.description == "\(failure.path): Permission denied"
        }
        #expect(recorded == "Asia/Seoul")
    }

    /// A marker that's there but doesn't read as a zone says nothing of the
    /// pages' zone, so they go; only a missing one means a phase 1 probe's.
    @Test(arguments: [Data([0xFF, 0xFE, 0x00, 0xC3]), Data("\n".utf8)])
    func `should start over when the recorded zone doesn't read`(marker: Data) throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeLedger()
        try FileManager.default.createDirectory(at: zoneFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try marker.write(to: zoneFile)

        #expect(try KeptZone(home: home).prepare(counting: "Asia/Seoul", own: "Asia/Seoul") == true)

        #expect(!exists("claude.json") && !exists("codex.json"))
        #expect(recorded == "Asia/Seoul")
    }

    /// A ledger it can't list may hold pages: it says so, and records nothing.
    @Test(.enabled(if: getuid() != 0, "root lists a folder it has no read permission on"))
    func `should say it couldn't list the ledger, and record nothing`() throws {
        defer {
            chmod(ledger.path, 0o755)
            try? FileManager.default.removeItem(at: home)
        }
        try makeLedger()
        try recordZone("Asia/Seoul")
        chmod(ledger.path, 0o311)

        #expect(throws: KeptZone.Failure(path: ledger.path, reason: "Permission denied")) {
            try KeptZone(home: home).prepare(counting: "America/Los_Angeles", own: "Asia/Seoul")
        }
        #expect(recorded == "Asia/Seoul")
    }

    /// `readdir` returns nil at the end and on an error alike; only `errno` tells them apart.
    @Test
    func `should say it couldn't read the ledger to its end`() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeLedger()

        #expect(throws: KeptZone.Failure(path: ledger.path, reason: String(cString: strerror(EIO)))) {
            try KeptZone.names(in: ledger.path) { _ in
                errno = EIO
                return nil
            }
        }
        #expect(try KeptZone.names(in: ledger.path).sorted() == ["claude.json", "codex.json", "scans"])
        #expect(try KeptZone.names(in: home.appendingPathComponent("none").path).isEmpty)
    }

    @Test
    func `should name the distro's own zone from its localtime link`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("localtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let zoneinfo = folder.appendingPathComponent("usr/share/zoneinfo")
        for name in ["Asia/Seoul", "America/Indiana/Indianapolis"] {
            let file = zoneinfo.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("TZif".utf8).write(to: file)
        }
        let link = folder.appendingPathComponent("localtime").path

        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: zoneinfo.appendingPathComponent("Asia/Seoul").path)
        #expect(KeptZone.distroZone(localtime: link) == "Asia/Seoul")

        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link,
                                                   withDestinationPath: zoneinfo.appendingPathComponent("America/Indiana/Indianapolis").path)
        #expect(KeptZone.distroZone(localtime: link) == "America/Indiana/Indianapolis")

        try FileManager.default.removeItem(atPath: link)
        try Data("TZif".utf8).write(to: URL(fileURLWithPath: link))
        #expect(KeptZone.distroZone(localtime: link) == nil)
    }

    @Test
    func `should name the link's own target, not what that target links to`() throws {
        // Etc/UTC may itself be a link (to Etc/UCT or the like): the zone is the name /etc/localtime points at.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("localtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let zoneinfo = folder.appendingPathComponent("usr/share/zoneinfo")
        try FileManager.default.createDirectory(at: zoneinfo.appendingPathComponent("Etc"), withIntermediateDirectories: true)
        try Data("TZif".utf8).write(to: zoneinfo.appendingPathComponent("Etc/UCT"))
        try FileManager.default.createSymbolicLink(atPath: zoneinfo.appendingPathComponent("Etc/UTC").path, withDestinationPath: "UCT")
        let link = folder.appendingPathComponent("localtime").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "usr/share/zoneinfo/Etc/UTC")

        #expect(KeptZone.distroZone(localtime: link) == "Etc/UTC")
    }
}
