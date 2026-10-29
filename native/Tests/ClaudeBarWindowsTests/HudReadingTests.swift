import Foundation
import Quotas
import Testing
@testable import ClaudeBarWindows

/// What the HUD shows for each tool's limits (docs/plans/2026-10-13-hud-design.md),
/// read through ClaudeBar's own rules so a limit reads the same as on the Mac.
@Suite
struct HudReadingTests {
    private let now = Date()
    private let hour = 3600.0
    private let day = 86_400.0

    private func quota(_ type: QuotaType, left: Double, resetsIn: TimeInterval?, window: TimeInterval?,
                       provider: String = "claude") -> UsageQuota {
        UsageQuota(percentRemaining: left, quotaType: type, providerId: provider,
                   resetsAt: resetsIn.map { now.addingTimeInterval($0) }, windowDuration: window)
    }

    private func snapshot(_ provider: String, _ quotas: [UsageQuota]) -> UsageSnapshot {
        UsageSnapshot(providerId: provider, quotas: quotas, capturedAt: now)
    }

    @Test func `should give each limit its window, the share left and when it resets, in the tool's order`() {
        let reading = HudReading(snapshots: [snapshot("claude", [
            quota(.session, left: 62.7, resetsIn: 2 * hour + 14 * 60, window: 5 * hour),
            quota(.weekly, left: 71, resetsIn: 3 * day + 6 * hour, window: 7 * day),
        ])], policy: .absolute)

        let lines = reading.tools[0].lines
        #expect(reading.tools.map(\.id) == ["claude"])
        #expect(lines.map(\.window) == ["5h", "7d"])
        #expect(lines.map(\.percentLeft) == [62, 71])
        #expect(lines.map(\.resetsAt) == [now.addingTimeInterval(2 * hour + 14 * 60), now.addingTimeInterval(3 * day + 6 * hour)])
    }

    @Test func `should say a limit is running hot when it is ahead of an even pace, with the tick where an even pace would end`() {
        // 59% used with 53.6% of the week gone.
        let reading = HudReading(snapshots: [snapshot("claude", [
            quota(.weekly, left: 41, resetsIn: 3 * day + 6 * hour, window: 7 * day),
        ])], policy: .absolute)

        let line = reading.tools[0].lines[0]
        #expect(line.runningHot)
        #expect(reading.tools[0].runningHot)
        #expect(abs((line.tick ?? 0) - 46.43) < 0.05)
    }

    @Test func `should say a tool is out until the earliest of its limits at 0 resets`() {
        let reading = HudReading(snapshots: [snapshot("claude", [
            quota(.session, left: 0, resetsIn: 1 * hour, window: 5 * hour),
            quota(.weekly, left: 38, resetsIn: 3 * day, window: 7 * day),
        ])], policy: .absolute)

        #expect(reading.tools[0].outUntil == now.addingTimeInterval(1 * hour))
        #expect(reading.tools[0].lines[0].status == "depleted")
    }

    @Test func `should colour a limit under the person's policy, not always by the share left`() {
        // 45% left with 80% of the week gone: low by share, fine by pace.
        let quotas = [quota(.weekly, left: 45, resetsIn: 0.2 * 7 * day, window: 7 * day)]

        #expect(HudReading(snapshots: [snapshot("claude", quotas)], policy: .absolute).tools[0].lines[0].status == "warning")
        #expect(HudReading(snapshots: [snapshot("claude", quotas)], policy: .paceAware).tools[0].lines[0].status == "healthy")
    }

    @Test func `should put each tool's shortest limit on the strip, and another only while it needs you`() {
        let reading = HudReading(snapshots: [
            snapshot("claude", [
                quota(.session, left: 62, resetsIn: 2 * hour, window: 5 * hour),
                quota(.weekly, left: 71, resetsIn: 5 * day, window: 7 * day),
            ]),
            snapshot("codex", [
                quota(.session, left: 88, resetsIn: 4 * hour, window: 5 * hour, provider: "codex"),
                quota(.weekly, left: 41, resetsIn: 3 * day, window: 7 * day, provider: "codex"),
            ]),
        ], policy: .absolute)

        #expect(reading.tools[0].lines.map(\.strip) == [true, false])
        #expect(reading.tools[1].lines.map(\.strip) == [true, true])
    }

    @Test func `should leave a balance with no ceiling off the HUD, as it has no share to show`() {
        let credits = UsageQuota(percentRemaining: 100, quotaType: .timeLimit("Credits"), providerId: "claude", dollarRemaining: 12)
        let reading = HudReading(snapshots: [snapshot("claude", [
            credits,
            quota(.session, left: 62, resetsIn: 2 * hour, window: 5 * hour),
        ])], policy: .absolute)

        #expect(reading.tools[0].lines.map(\.window) == ["5h"])
    }

    @Test func `should name the worst status of every limit, for the taskbar dot`() {
        let reading = HudReading(snapshots: [
            snapshot("claude", [quota(.session, left: 62, resetsIn: 2 * hour, window: 5 * hour)]),
            snapshot("codex", [quota(.session, left: 12, resetsIn: 2 * hour, window: 5 * hour, provider: "codex")]),
        ], policy: .absolute)

        #expect(reading.worst == "critical")
        #expect(HudReading(snapshots: [], policy: .absolute).worst == "healthy")
    }
}
