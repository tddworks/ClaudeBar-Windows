import Foundation
import Quotas
import Testing
@testable import ClaudeBarShared

/// The HUD's answer crosses from the probe to the app as JSON
/// (docs/plans/2026-11-03-wsl-design.md, Keeping the probe and the app in step).
@Suite
struct HudCodableTests {
    @Test func `should read back the answer it wrote, dates and all`() throws {
        let now = Date(timeIntervalSince1970: 1_762_230_000)
        let quota = UsageQuota(percentRemaining: 62, quotaType: .session, providerId: "claude",
                               resetsAt: now.addingTimeInterval(7200), windowDuration: 5 * 3600)
        let reading = HudReading(snapshots: [UsageSnapshot(providerId: "claude", quotas: [quota], capturedAt: now)], policy: .absolute)
        let answer = HudMonitor.Answer(reading: reading, readAt: now,
                                       problems: [HudMonitor.Problem(id: "codex", kind: "signedOut", message: "Run codex login")],
                                       looks: [HudMonitor.Look(id: "claude", name: "Claude", light: "#D97757", dark: "#D97757")])

        let data = try encoder.encode(answer)

        #expect(try decoder.decode(HudMonitor.Answer.self, from: data) == answer)
    }

    @Test func `should write dates as seconds since 1970, as cbw_hud_reading does`() throws {
        let answer = HudMonitor.Answer(reading: HudReading(snapshots: [], policy: .absolute),
                                       readAt: Date(timeIntervalSince1970: 1_762_230_000), problems: [], looks: [])
        let object = try JSONSerialization.jsonObject(with: encoder.encode(answer)) as? [String: Any]
        #expect(object?["readAt"] as? Double == 1_762_230_000)
    }

    private var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
    private var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}
