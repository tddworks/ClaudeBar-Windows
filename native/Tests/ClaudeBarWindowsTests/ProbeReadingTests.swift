import Foundation
import Leaderboard
import Testing
@testable import ClaudeBarShared

/// The probe's answer (docs/plans/2026-11-03-wsl-design.md, The probe): one
/// type, encoded in the distro and decoded on Windows from the same source.
@Suite
struct ProbeReadingTests {
    private var sample: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../tests/wsl-probe.json").standardized
    }

    @Test func `should read the checked-in sample, so a field renamed on one side fails`() throws {
        let reading = try ProbeReading.decoder().decode(ProbeReading.self, from: Data(contentsOf: sample))

        #expect(reading.version == ClientVersion.version, "tests/wsl-probe.json says the version the app runs, or WslProbe turns it away")
        #expect(reading.days.map(\.day) == ["2026-11-03", "2026-11-04"])
        #expect(reading.hud?.reading.tools.map(\.id) == ["claude"])
        #expect(reading.skipped.map(\.reason) == [.shared, .uncheckable])
        #expect(reading.environmentImport.state == .imported)
    }

    @Test func `should write the sample back byte for byte`() throws {
        let data = try Data(contentsOf: sample)
        let reading = try ProbeReading.decoder().decode(ProbeReading.self, from: data)
        let text = String(decoding: try ProbeReading.encoder().encode(reading), as: UTF8.self)

        #expect(text == String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
                            .trimmingCharacters(in: .newlines))
    }

    @Test func `should carry day labels and counts, never dates`() throws {
        let day = DailyTokens(provider: "claude", day: "2026-11-04", input: 1, output: 2, cacheWrite: 3, cacheRead: 4, unsplit: 5)
        let reading = ProbeReading(version: "0.1.9", hud: nil, days: [day], tools: [], skipped: [], timeZone: "UTC",
                                   timedOut: false, environmentImport: .init(state: .failed, names: [], reason: "timed out after 3 s"),
                                   diagnostics: [])

        let back = try ProbeReading.decoder().decode(ProbeReading.self, from: ProbeReading.encoder().encode(reading))

        #expect(back == reading)
        #expect(back.hud == nil)
    }
}
