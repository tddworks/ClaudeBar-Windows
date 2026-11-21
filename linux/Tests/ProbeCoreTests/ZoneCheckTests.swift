#if os(Linux)
import ClaudeBarShared
@testable import DataSources
import Foundation
import ProbeCore
import Testing

/// The probe counts in TZ only when ClaudeBar's LinuxTimeZone can
/// (docs/plans/2026-11-03-wsl-design.md, The time zone): a file under
/// /usr/share/zoneinfo and a name Foundation knows, as itself.
@Suite
struct ZoneCheckTests {
    private let zoneinfo = FileManager.default.temporaryDirectory.appendingPathComponent("zoneinfo-\(UUID().uuidString)")

    private func makeZone(_ name: String) throws {
        let file = zoneinfo.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("TZif".utf8).write(to: file)
    }

    @Test func `should take no TZ as no zone asked`() {
        #expect(ZoneCheck.check(nil, zoneinfo: zoneinfo.path) == .none)
        #expect(ZoneCheck.check("", zoneinfo: zoneinfo.path) == .none)
    }

    @Test func `should accept a zone with a file that Foundation knows`() throws {
        defer { try? FileManager.default.removeItem(at: zoneinfo) }
        try makeZone("Asia/Seoul")
        #expect(ZoneCheck.check("Asia/Seoul", zoneinfo: zoneinfo.path) == .accepted("Asia/Seoul"))
    }

    @Test func `should refuse a name with no file, as without tzdata-legacy`() {
        #expect(ZoneCheck.check("Asia/Calcutta", zoneinfo: zoneinfo.path)
                == .refused("no time zone data for Asia/Calcutta (\(zoneinfo.path)/Asia/Calcutta)"))
    }

    @Test func `should refuse a file Foundation doesn't know, and Foundation's own offset names`() throws {
        defer { try? FileManager.default.removeItem(at: zoneinfo) }
        try makeZone("Nowhere/Zone")
        #expect(ZoneCheck.check("Nowhere/Zone", zoneinfo: zoneinfo.path) == .refused("no time zone named Nowhere/Zone"))
        // Foundation's own name for an offset has no file in any tzdata, so it is refused there.
        #expect(ZoneCheck.check("GMT+0900") == .refused("no time zone data for GMT+0900 (/usr/share/zoneinfo/GMT+0900)"))
    }

    @Test(arguments: ["../../etc/passwd", "/etc/localtime", ":Asia/Seoul", "Asia//Seoul", "Asia/Seoul/"])
    func `should refuse a TZ that isn't a plain zone name`(tz: String) {
        #expect(ZoneCheck.check(tz, zoneinfo: "/usr/share/zoneinfo") == .refused("TZ \(tz) isn't a zone name"))
    }

    /// Every zone the app can send, from ClaudeBar's own table, is one this
    /// runner's tzdata (noble's, no tzdata-legacy, as the PC's Ubuntu) counts in,
    /// by the same name the probe then answers with.
    @Test func `should accept every name the app can send`() {
        let now = Date()
        var names = Set<String>()
        for (key, iana) in WindowsZones.iana {
            let offset = TimeZone(identifier: iana)?.secondsFromGMT(for: now) ?? 0
            for daylightSavingOff in [false, true] {
                let zone = WindowsZones.zone(key: key, daylightSavingOff: daylightSavingOff, secondsFromGMT: offset)
                if let name = WslZone.name(for: zone, at: now) { names.insert(name) }
                else { #expect(offset % 3600 != 0, "\(key) gives no name") }
            }
        }
        #expect(names.count > 100)
        for name in names.sorted() {
            #expect(ZoneCheck.check(name) == .accepted(name), "\(name)")
            #expect(TimeZone(identifier: name)?.identifier == name, "\(name) answers as another name")
        }
    }

    @Test func `should run where the seven old names have no file, as on the PC`() {
        for old in WslZone.renamed.keys { #expect(!FileManager.default.fileExists(atPath: "/usr/share/zoneinfo/\(old)"), "\(old)") }
    }
}
#endif
