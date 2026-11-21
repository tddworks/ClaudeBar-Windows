import Foundation
import Testing
@testable import ClaudeBarShared

/// The zone a distro's days are counted in (docs/plans/2026-11-03-wsl-design.md,
/// The time zone): Windows' own, by a name the distro's tzdata has.
@Suite
struct WslZoneTests {
    private let now = Date(timeIntervalSince1970: 1_762_930_000)   // 2025-11-12

    @Test func `should send a named zone by its own name`() {
        #expect(WslZone.name(for: TimeZone(identifier: "Asia/Seoul")!, at: now) == "Asia/Seoul")
        #expect(WslZone.name(for: TimeZone(identifier: "America/Los_Angeles")!, at: now) == "America/Los_Angeles")
        #expect(WslZone.name(for: TimeZone(identifier: "Etc/GMT+12")!, at: now) == "Etc/GMT+12")
    }

    @Test(arguments: [
        ("Asia/Calcutta", "Asia/Kolkata"), ("Asia/Katmandu", "Asia/Kathmandu"), ("Asia/Rangoon", "Asia/Yangon"),
        ("Europe/Kiev", "Europe/Kyiv"), ("America/Buenos_Aires", "America/Argentina/Buenos_Aires"),
        ("America/Godthab", "America/Nuuk"), ("America/Indianapolis", "America/Indiana/Indianapolis"),
    ])
    func `should send CLDR's seven old names by their current ones`(old: String, current: String) {
        #expect(WslZone.renamed[old] == current)
        if let zone = TimeZone(identifier: old) { #expect(WslZone.name(for: zone, at: now) == current) }
        #expect(WslZone.name(for: TimeZone(identifier: current)!, at: now) == current)
    }

    @Test func `should send a fixed offset of whole hours as Etc, POSIX's sign reversed`() {
        #expect(WslZone.name(for: TimeZone(secondsFromGMT: 9 * 3600)!, at: now) == "Etc/GMT-9")
        #expect(WslZone.name(for: TimeZone(secondsFromGMT: -5 * 3600)!, at: now) == "Etc/GMT+5")
        #expect(WslZone.name(for: TimeZone(secondsFromGMT: 14 * 3600)!, at: now) == "Etc/GMT-14")
        #expect(WslZone.name(for: TimeZone(secondsFromGMT: -12 * 3600)!, at: now) == "Etc/GMT+12")
    }

    @Test func `should send no offset as Etc UTC`() {
        #expect(WslZone.name(for: TimeZone(secondsFromGMT: 0)!, at: now) == "Etc/UTC")
    }

    @Test func `should send nothing for an offset tzdata has no name for`() {
        #expect(WslZone.name(for: TimeZone(secondsFromGMT: 19_800)!, at: now) == nil)        // +05:30
        #expect(WslZone.name(for: TimeZone(secondsFromGMT: -13 * 3600)!, at: now) == nil)   // no Etc/GMT+13
    }

    @Test func `should never send Foundation's own name for an offset`() {
        for seconds in stride(from: -14 * 3600, through: 14 * 3600, by: 1800) {
            let name = WslZone.name(for: TimeZone(secondsFromGMT: seconds)!, at: now)
            #expect(name.map { !$0.hasPrefix("GMT") } ?? true, "\(seconds): \(name ?? "nil")")
        }
    }

    /// What `name(for:at:)` tells a fixed offset by: Foundation's name for one
    /// (`GMT+0900`, `GMT`) has no `/`, on each platform the app or the probe runs.
    @Test func `should find no slash in Foundation's name for a fixed offset`() {
        for seconds in stride(from: -14 * 3600, through: 14 * 3600, by: 1800) {
            let identifier = TimeZone(secondsFromGMT: seconds)!.identifier
            #expect(!identifier.contains("/") && identifier.hasPrefix("GMT"), "\(seconds): \(identifier)")
        }
    }
}
