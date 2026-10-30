import Foundation
import Providers
import Quotas
import Testing
@testable import ClaudeBarWindows

/// How an aggregator's groups reach the app (docs/plans/2026-10-13-hud-design.md,
/// Groups): each in its own product's colours, named as its section is, and
/// sharing the aggregator's problem.
@MainActor
@Suite
struct HudGroupsTests {
    private let now = Date()
    private let definitions = Array(ProviderFactory.builtInDefinitions.values)
    private let omp = HudMonitor.Look(id: "omp", name: "Oh My Pi", light: "#299E61", dark: "#4DD98C")

    private func reading(_ groups: [String?]) -> HudReading {
        HudReading(snapshots: [
            UsageSnapshot(providerId: "claude", quotas: [UsageQuota(percentRemaining: 62, quotaType: .session, providerId: "claude")], capturedAt: now),
            UsageSnapshot(providerId: "omp", quotas: groups.enumerated().map { index, group in
                UsageQuota(percentRemaining: 50, quotaType: .timeLimit("Limit \(index)"), providerId: "omp", group: group)
            }, capturedAt: now),
        ], policy: .absolute)
    }

    private func colours(of id: String) throws -> (String, String) {
        let color = try #require(definitions.first { $0.id == id }).profile.look.color
        return (ProviderTokenLogs.hex(color?.light), ProviderTokenLogs.hex(color?.dark))
    }

    @Test func `should draw each group in the colours of the product it names, after the aggregator's own look`() throws {
        let claude = HudMonitor.Look(id: "claude", name: "Claude", light: "#D97757", dark: "#E08A6D")

        let looks = HudMonitor.looks([claude, omp], for: reading(["Claude", "Codex", "Kimi"]), definitions: definitions)

        #expect(looks.map(\.id) == ["claude", "omp", "omp/Claude", "omp/Codex", "omp/Kimi"])
        #expect(looks.map(\.name) == ["Claude", "Oh My Pi", "Claude", "Codex", "Kimi"])
        for (look, id) in zip(looks.dropFirst(2), ["claude", "codex", "kimi"]) {
            let (light, dark) = try colours(of: id)
            #expect((look.light, look.dark) == (light, dark), "\(look.id) in \(id)'s colours")
        }
    }

    @Test func `should name an account's group as the Mac's menu bar shortens it, in its product's colours`() throws {
        let looks = HudMonitor.looks([omp], for: reading(["Claude · jkjk98765", "Claude · work"]), definitions: definitions)

        #expect(looks.map(\.id) == ["omp", "omp/Claude · jkjk98765", "omp/Claude · work"])
        #expect(looks.map(\.name) == ["Oh My Pi", "Claude · jkjk987…", "Claude · work"])
        let (light, dark) = try colours(of: "claude")
        #expect(looks.dropFirst().allSatisfy { ($0.light, $0.dark) == (light, dark) })
    }

    @Test func `should draw a group no product is named for in the aggregator's colours`() {
        let looks = HudMonitor.looks([omp], for: reading(["Mystery Cloud"]), definitions: definitions)

        #expect(looks.last == HudMonitor.Look(id: "omp/Mystery Cloud", name: "Mystery Cloud", light: omp.light, dark: omp.dark))
    }

    @Test func `should give the aggregator's problem to each of its groups while it has their numbers`() {
        let problems = [HudMonitor.Problem(id: "omp", kind: "failed", message: "omp usage timed out"),
                        HudMonitor.Problem(id: "codex", kind: "signedOut", message: "Sign in")]

        let spread = HudMonitor.spread(problems, over: reading(["Claude", nil, "Codex"]))

        #expect(spread.map(\.id) == ["omp/Claude", "omp", "omp/Codex", "codex"])
        #expect(spread.map(\.kind) == ["failed", "failed", "failed", "signedOut"])
        #expect(spread.dropLast().allSatisfy { $0.message == "omp usage timed out" })
    }

    @Test func `should keep the aggregator's own problem while it has no numbers to split`() {
        let problems = [HudMonitor.Problem(id: "omp", kind: "reading", message: "")]

        #expect(HudMonitor.spread(problems, over: HudReading(snapshots: [], policy: .absolute)) == problems)
    }
}
