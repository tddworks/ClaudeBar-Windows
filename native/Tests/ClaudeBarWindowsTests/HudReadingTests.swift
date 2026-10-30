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

    // MARK: - The headline: the one line that stops the person first (design, What it shows)

    @Test func `should headline the worse status before the lower share`() {
        // Out beats low and running hot.
        let out = HudReading(snapshots: [snapshot("claude", [
            quota(.weekly, left: 10, resetsIn: 0.9 * 7 * day, window: 7 * day),
            quota(.session, left: 0, resetsIn: 1 * hour, window: 5 * hour),
        ])], policy: .absolute).tools[0]
        // Pace-aware: 45% left and running out is a warning, 40% left with room to spare is fine.
        let paced = HudReading(snapshots: [snapshot("claude", [
            quota(.session, left: 40, resetsIn: 0.5 * hour, window: 5 * hour),
            quota(.weekly, left: 45, resetsIn: 0.8 * 7 * day, window: 7 * day),
        ])], policy: .paceAware).tools[0]

        #expect(out.lines.map(\.status) == ["critical", "depleted"])
        #expect(out.headline == 1)
        #expect(paced.lines.map(\.status) == ["healthy", "warning"])
        #expect(paced.headline == 1)
    }

    @Test func `should headline a limit running hot before a lower one at the same status`() {
        let tool = HudReading(snapshots: [snapshot("claude", [
            // 45% used with 80% of the window gone: room to spare.
            quota(.session, left: 55, resetsIn: 1 * hour, window: 5 * hour),
            // 40% used with 20% of the week gone: running hot.
            quota(.weekly, left: 60, resetsIn: 0.8 * 7 * day, window: 7 * day),
        ])], policy: .absolute).tools[0]

        #expect(tool.lines.map(\.status) == ["healthy", "healthy"])
        #expect(tool.lines.map(\.runningHot) == [false, true])
        #expect(tool.headline == 1)
    }

    @Test func `should say when a limit running hot runs out at its pace, and when the tool's numbers were read`() throws {
        let reading = HudReading(snapshots: [snapshot("claude", [
            quota(.session, left: 55, resetsIn: 1 * hour, window: 5 * hour),
            // 40% used in 20% of the week: twice an even pace, so its 60% lasts 30% of the week.
            quota(.weekly, left: 60, resetsIn: 0.8 * 7 * day, window: 7 * day),
        ])], policy: .absolute)

        let lines = reading.tools[0].lines
        #expect(lines[0].runsOutAt == nil)
        let runsOut = try #require(lines[1].runsOutAt)
        #expect(abs(runsOut.timeIntervalSince(now.addingTimeInterval(0.3 * 7 * day))) < 60)
        #expect(reading.tools[0].readAt == now)
    }

    @Test func `should headline the lowest share among healthy limits`() {
        let tool = HudReading(snapshots: [snapshot("omp", [
            quota(.timeLimit("Codex 7d"), left: 80, resetsIn: nil, window: nil, provider: "omp"),
            quota(.timeLimit("Kimi 7d"), left: 55, resetsIn: nil, window: nil, provider: "omp"),
            quota(.timeLimit("Claude 5h"), left: 70, resetsIn: nil, window: nil, provider: "omp"),
        ])], policy: .absolute).tools[0]

        #expect(tool.headline == 1)
    }

    @Test func `should headline the limit that resets soonest when the shares tie`() {
        let tool = HudReading(snapshots: [snapshot("omp", [
            quota(.timeLimit("Claude 5h"), left: 60, resetsIn: 3 * hour, window: nil, provider: "omp"),
            quota(.timeLimit("Kimi 5h"), left: 60, resetsIn: 1 * hour, window: nil, provider: "omp"),
            quota(.timeLimit("Codex 5h"), left: 60, resetsIn: nil, window: nil, provider: "omp"),
        ])], policy: .absolute).tools[0]

        #expect(tool.headline == 1)
    }

    @Test func `should count the other limits and those that need you, without the headline`() {
        let tool = HudReading(snapshots: [snapshot("omp", [
            quota(.timeLimit("Codex 7d"), left: 80, resetsIn: nil, window: nil, provider: "omp"),
            quota(.timeLimit("Kimi 7d"), left: 40, resetsIn: nil, window: nil, provider: "omp"),
            quota(.timeLimit("Claude 5h"), left: 10, resetsIn: nil, window: nil, provider: "omp"),
            quota(.timeLimit("Claude 7d"), left: 90, resetsIn: nil, window: nil, provider: "omp"),
        ])], policy: .absolute).tools[0]

        #expect(tool.headline == 2)
        #expect(tool.others == HudReading.Others(count: 3, attention: 1))
    }

    @Test func `should have no others for a tool with one limit`() {
        let tool = HudReading(snapshots: [snapshot("claude", [
            quota(.session, left: 12, resetsIn: 2 * hour, window: 5 * hour),
        ])], policy: .absolute).tools[0]

        #expect(tool.headline == 0)
        #expect(tool.others == HudReading.Others(count: 0, attention: 0))
    }
}
