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
        /// Whether the strip shows it: the tool's shortest window, or a limit that needs you.
        public let strip: Bool
    }

    public struct Tool: Equatable, Sendable, Encodable {
        public let id: String
        public let lines: [Line]
        /// When the earliest of its limits at 0 comes back.
        public let outUntil: Date?
        public let runningHot: Bool
    }

    public let tools: [Tool]
    /// The worst status of every line, for the taskbar dot.
    public let worst: String

    public init(snapshots: [UsageSnapshot], policy: StatusPolicy) {
        var worst = QuotaStatus.healthy
        tools = snapshots.map { snapshot in
            // A balance with no ceiling has no share to draw; the window shows it.
            let quotas = snapshot.quotas.filter { !$0.isBalance && $0.percentLeft != nil }
            let shortest = quotas.min { ($0.windowDuration ?? .infinity) < ($1.windowDuration ?? .infinity) }
            let lines = quotas.map { quota in
                let status = quota.status(under: policy)
                worst = max(worst, status)
                let hot = quota.pace == .ahead
                return Line(
                    window: quota.compactTitle ?? quota.quotaType.shortLabel,
                    percentLeft: Int(quota.percentLeft ?? quota.percentRemaining),
                    resetsAt: quota.resetsAt,
                    windowSeconds: quota.windowDuration,
                    status: status.name,
                    runningHot: hot,
                    tick: quota.expectedProgressPercent(mode: .remaining),
                    strip: quota == shortest || status != .healthy || hot
                )
            }
            let out = zip(quotas, lines).filter { $0.1.status == "depleted" }.compactMap { $0.0.resetsAt }.min()
            return Tool(id: snapshot.providerId, lines: lines, outUntil: out, runningHot: lines.contains(where: \.runningHot))
        }
        self.worst = worst.name
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
