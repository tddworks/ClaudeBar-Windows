import Foundation
import Quotas

/// What the HUD shows (docs/plans/2026-10-13-hud-design.md): for each signed-in
/// tool, a line per limit, read through ClaudeBar's own rules (status under
/// the person's policy, pace, the expected-pace tick), so a limit reads the
/// same on Windows as in the Mac's popover. Numbers and dates, not words:
/// the app formats them in the person's language.
public struct HudReading: Equatable, Sendable, Encodable {
    public struct Line: Equatable, Sendable, Encodable {
        /// The window's short name: the quota's compact title, or "5h", "7d".
        public let window: String
        /// The share left, as the Mac shows it (whole percent, rounded down).
        public let percentLeft: Int
        public let resetsAt: Date?
        /// The window's length in seconds, when the data source states it.
        public let windowSeconds: Double?
        /// `healthy`, `warning`, `critical` or `depleted`, under the person's policy.
        public let status: String
        /// Ahead of an even pace: the Mac's "Running hot".
        public let runningHot: Bool
        /// Where the bar would end at an even pace (0–100), when the window is known.
        public let tick: Double?
        /// When a limit running hot reaches 0 at its pace: ClaudeBar's forecast.
        public let runsOutAt: Date?
        /// Whether the strip shows it: the tool's shortest window, or a limit that needs you.
        public let strip: Bool
    }

    /// The tool's limits besides its headline, and how many of them need you.
    public struct Others: Equatable, Sendable, Encodable {
        public let count: Int
        /// Those that aren't healthy.
        public let attention: Int
    }

    public struct Tool: Equatable, Sendable, Encodable {
        public let id: String
        public let lines: [Line]
        /// The index in `lines` of the limit that stops the person first;
        /// `nil` when the tool has no limit with a share.
        public let headline: Int?
        public let others: Others
        /// When the earliest of its limits at 0 comes back.
        public let outUntil: Date?
        public let runningHot: Bool
        /// When its numbers were read.
        public let readAt: Date
    }

    public let tools: [Tool]
    /// The worst status of every line, for the taskbar dot.
    public let worst: String

    public init(snapshots: [UsageSnapshot], policy: StatusPolicy) {
        let now = Date()
        var worst = QuotaStatus.healthy
        tools = snapshots.map { snapshot in
            // A balance with no ceiling has no share to draw; the window shows it.
            let quotas = snapshot.quotas.filter { !$0.isBalance && $0.percentLeft != nil }
            let shortest = quotas.min { ($0.windowDuration ?? .infinity) < ($1.windowDuration ?? .infinity) }
            let statuses = quotas.map { $0.status(under: policy, at: now) }
            worst = max(worst, statuses.max() ?? .healthy)
            let lines = zip(quotas, statuses).map { quota, status in
                let hot = quota.pace(at: now) == .ahead
                return Line(
                    window: quota.compactTitle ?? quota.quotaType.shortLabel,
                    percentLeft: Int(quota.percentLeft ?? quota.percentRemaining),
                    resetsAt: quota.resetsAt,
                    windowSeconds: quota.windowDuration,
                    status: status.name,
                    runningHot: hot,
                    tick: quota.expectedProgressPercent(mode: .remaining),
                    runsOutAt: quota.forecast(at: now).flatMap(\.runsOutIn).map { now.addingTimeInterval($0) },
                    strip: quota == shortest || status != .healthy || hot
                )
            }
            let headline = Self.headline(of: quotas, statuses: statuses, lines: lines)
            let others = statuses.indices.filter { $0 != headline }
            let out = zip(quotas, lines).filter { $0.1.status == "depleted" }.compactMap { $0.0.resetsAt }.min()
            return Tool(id: snapshot.providerId, lines: lines, headline: headline,
                        others: Others(count: others.count, attention: others.filter { statuses[$0] != .healthy }.count),
                        outUntil: out, runningHot: lines.contains(where: \.runningHot), readAt: snapshot.capturedAt)
        }
        self.worst = worst.name
    }

    /// The limit that stops the person first: the worst status, then one
    /// running hot, then the least left, then the soonest reset. The first
    /// listed wins a full tie.
    private static func headline(of quotas: [UsageQuota], statuses: [QuotaStatus], lines: [Line]) -> Int? {
        quotas.indices.min { a, b in
            if statuses[a] != statuses[b] { return statuses[a] > statuses[b] }
            if lines[a].runningHot != lines[b].runningHot { return lines[a].runningHot }
            let left = (quotas[a].percentLeft ?? 0, quotas[b].percentLeft ?? 0)
            if left.0 != left.1 { return left.0 < left.1 }
            return (quotas[a].resetsAt ?? .distantFuture) < (quotas[b].resetsAt ?? .distantFuture)
        }
    }
}

private extension Forecast {
    /// Seconds until it runs out, when it runs out before the reset.
    var runsOutIn: TimeInterval? {
        guard case .runsOut(let after, _) = self else { return nil }
        let parts = after.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private extension QuotaStatus {
    var name: String {
        switch self {
        case .healthy: "healthy"
        case .warning: "warning"
        case .critical: "critical"
        case .depleted: "depleted"
        }
    }
}
