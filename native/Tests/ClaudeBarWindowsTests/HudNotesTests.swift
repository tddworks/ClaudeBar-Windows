import Foundation
import Quotas
import Testing
@testable import ClaudeBarWindows

/// What the Mac's card shows beside a tool's limits, sent to the app too
/// (docs/plans/2026-10-13-hud-design.md, Notes and plans): a group's notes,
/// a login's own notes, its plan, and an account omp signed out.
/// The notes are shaped as ClaudeBar maps them: omp's script writes each as
/// `{group, label, text}` (`ScriptOutput`: label, the text as the value, no
/// unit); a definition's `notes` give a label, a value and a unit.
@MainActor
@Suite
struct HudNotesTests {
    private let now = Date()

    private func omp(_ label: String, _ text: String, group: String) -> ExtensionMetric {
        ExtensionMetric(label: label, value: text, unit: "", group: group)
    }

    private func limit(_ name: String, group: String, left: Double = 62) -> UsageQuota {
        UsageQuota(percentRemaining: left, quotaType: .timeLimit(name), providerId: "omp", group: group)
    }

    @Test func `should keep a signed-out account omp reports with no limits, as a group of its own that says it's signed out`() throws {
        let reading = HudReading(snapshots: [UsageSnapshot(
            providerId: "omp", quotas: [limit("Codex 7d", group: "Codex")], capturedAt: now,
            extensionMetrics: [omp("Claude · josh@example.com", "Signed out · Refresh token revoked · run omp login", group: "Claude · josh")]
        )], policy: .absolute)

        #expect(reading.tools.map(\.id) == ["omp/Codex", "omp/Claude · josh"])
        let signedOut = try #require(reading.tools.last)
        #expect(signedOut.group == "Claude · josh")
        #expect(signedOut.via == "omp")
        #expect(signedOut.lines.isEmpty)
        #expect(signedOut.signedOut)
        #expect(signedOut.notes == [HudReading.Note(label: nil, value: "Signed out · Refresh token revoked · run omp login", unit: "")])
        #expect(!reading.tools[0].signedOut)
    }

    @Test func `should put omp's saved resets on the group they're for, above its limits, as the note alone`() throws {
        let reading = HudReading(snapshots: [UsageSnapshot(
            providerId: "omp", quotas: [limit("Codex 5h", group: "Codex"), limit("Codex 7d", group: "Codex")], capturedAt: now,
            extensionMetrics: [omp("Codex Saved resets", "1 saved reset · next expires Nov 7", group: "Codex")]
        )], policy: .absolute)

        let codex = try #require(reading.tools.only)
        #expect(codex.lines.map(\.window) == ["5h", "7d"])
        #expect(codex.notes == [HudReading.Note(label: nil, value: "1 saved reset · next expires Nov 7", unit: "")])
        #expect(!codex.signedOut)
    }

    @Test func `should keep a balance omp writes as a note, on a group with no limit to draw, after the groups with limits`() {
        let reading = HudReading(snapshots: [UsageSnapshot(
            providerId: "omp", quotas: [limit("Kimi 7d", group: "Kimi")], capturedAt: now,
            extensionMetrics: [omp("OpenRouter Credits", "$12.50 left", group: "OpenRouter"),
                               omp("Qwen Cloud · API key", "No usage reported", group: "Qwen Cloud · API key")]
        )], policy: .absolute)

        #expect(reading.tools.map(\.id) == ["omp/Kimi", "omp/OpenRouter", "omp/Qwen Cloud · API key"])
        #expect(reading.tools.map { $0.notes.map(\.value) } == [[], ["$12.50 left"], ["No usage reported"]])
        #expect(reading.tools.map(\.notesOnly) == [false, true, true])
        #expect(reading.tools.allSatisfy { !$0.signedOut })
    }

    @Test func `should give a login's own notes their label and unit, as the Mac's metric card does`() throws {
        // Codex: its resets, and after ClaudeBar #675 its credits.
        let reading = HudReading(snapshots: [UsageSnapshot(
            providerId: "codex",
            quotas: [UsageQuota(percentRemaining: 71, quotaType: .weekly, providerId: "codex", windowDuration: 7 * 86_400)],
            capturedAt: now,
            accountTier: .custom("PRO"),
            extensionMetrics: [ExtensionMetric(label: "Usage limit resets", value: "2", unit: "available"),
                               ExtensionMetric(label: "Credits", value: "59,691", unit: "credits")]
        )], policy: .absolute)

        let codex = try #require(reading.tools.only)
        #expect(codex.notes == [HudReading.Note(label: "Usage limit resets", value: "2", unit: "available"),
                                HudReading.Note(label: "Credits", value: "59,691", unit: "credits")])
        #expect(codex.tier == "PRO")
        #expect(!codex.notesOnly)
    }

    @Test func `should keep a login with notes and no limit as one tool, not a group`() throws {
        let reading = HudReading(snapshots: [UsageSnapshot(
            providerId: "codex", quotas: [], capturedAt: now,
            extensionMetrics: [ExtensionMetric(label: "Credits", value: "Unlimited", unit: "")]
        )], policy: .absolute)

        let codex = try #require(reading.tools.only)
        #expect(codex.id == "codex")
        #expect(codex.group == nil)
        #expect(codex.notes.map(\.label) == ["Credits"])
        #expect(!codex.notesOnly)
    }

    @Test func `should name Claude's plan as its badge says, ULTRA, MAX or TEAM`() {
        let tiers: [AccountTier] = [.custom("ULTRA"), .claudeMax, .custom("TEAM")]
        let reading = HudReading(snapshots: tiers.enumerated().map { index, tier in
            UsageSnapshot(providerId: "claude\(index)", quotas: [UsageQuota(percentRemaining: 80, quotaType: .weekly, providerId: "claude")],
                          capturedAt: now, accountTier: tier)
        }, policy: .absolute)

        #expect(reading.tools.map(\.tier) == ["ULTRA", "MAX", "TEAM"])
    }

    @Test func `should send the notes, the plan and the signed-out flag over the C interface`() throws {
        let reading = HudReading(snapshots: [
            UsageSnapshot(providerId: "claude", quotas: [UsageQuota(percentRemaining: 80, quotaType: .weekly, providerId: "claude")],
                          capturedAt: now, accountTier: .custom("ULTRA")),
            UsageSnapshot(providerId: "omp", quotas: [], capturedAt: now,
                          extensionMetrics: [omp("Claude · old", "Signed out · run omp login", group: "Claude · old")]),
        ], policy: .absolute)

        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(reading)) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools[0]["tier"] as? String == "ULTRA")
        #expect(tools[0]["signedOut"] as? Bool == false)
        #expect((tools[0]["notes"] as? [Any])?.isEmpty == true)
        #expect(tools[1]["signedOut"] as? Bool == true)
        let note = try #require((tools[1]["notes"] as? [[String: Any]])?.first)
        #expect(note["value"] as? String == "Signed out · run omp login")
        #expect(note["label"] == nil)
        #expect(tools[1]["notesOnly"] == nil, "worked out again on the app's side, not sent")
    }

    @Test func `should read the notes and the plan the monitor holds, not only the limits`() {
        let snapshot = UsageSnapshot(providerId: "omp", quotas: [limit("Codex 7d", group: "Codex")], capturedAt: now,
                                     accountTier: .custom("PRO"),
                                     extensionMetrics: [omp("Claude · old", "Signed out · run omp login", group: "Claude · old")])

        let reading = HudReading(snapshots: [HudMonitor.renamed(snapshot, to: "omp.work")], policy: .absolute)

        #expect(reading.tools.map(\.id) == ["omp.work/Codex", "omp.work/Claude · old"])
        #expect(reading.tools.map(\.tier) == ["PRO", "PRO"])
        #expect(reading.tools.last?.signedOut == true)
    }

    @Test func `should not stale a group of notes alone with its aggregator's failure, having no numbers to stale`() {
        let reading = HudReading(snapshots: [UsageSnapshot(
            providerId: "omp", quotas: [limit("Codex 7d", group: "Codex")], capturedAt: now,
            extensionMetrics: [omp("Kimi · API key", "No usage reported", group: "Kimi · API key"),
                               omp("Claude · old", "Signed out · run omp login", group: "Claude · old")]
        )], policy: .absolute)

        let spread = HudMonitor.spread([HudMonitor.Problem(id: "omp", kind: "failed", message: "omp usage timed out")], over: reading)

        #expect(reading.tools.map(\.id) == ["omp/Codex", "omp/Kimi · API key", "omp/Claude · old"])
        #expect(spread.map(\.id) == ["omp/Codex"])
    }
}

private extension Array {
    /// The one element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
