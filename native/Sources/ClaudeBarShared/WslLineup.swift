import Foundation

/// A WSL distro as the HUD sees it: whether it's running, and its last
/// answer.
public struct WslDistro: Equatable, Sendable {
    public let name: String
    public let running: Bool
    /// The last answer, or the one kept in app.json.
    public let reading: ProbeReading?
    public let answeredAt: Date?
    /// Why the last run failed, when it did.
    public let failure: String?

    public init(name: String, running: Bool, reading: ProbeReading?, answeredAt: Date?, failure: String?) {
        self.name = name
        self.running = running
        self.reading = reading
        self.answeredAt = answeredAt
        self.failure = failure
    }
}

/// Each distro's tools in the HUD's lineup, after this PC's
/// (docs/plans/2026-11-03-wsl-design.md, The HUD, Limits and Settings), so
/// `cbw_hud_reading` keeps its shape. A distro's ids are prefixed with it
/// (`wsl:Ubuntu-26.04/claude`), and its names say WSL.
public enum WslLineup {
    /// The words of ClaudeBar's `Unavailable` (DataSources'
    /// `Internal/Unavailable.swift`): a source Linux has no connection for
    /// says it "isn't available on Linux yet". The text is the only signal;
    /// the probe leaves such a login out of its `tools` by it too.
    public static let unavailableOnLinux = "isn't available on Linux yet"

    /// What a login still reading at the probe's deadline says.
    static let tookTooLong = "Took too long in WSL"

    public static func id(_ id: String, in distro: String) -> String { "wsl:\(distro)/\(id)" }

    /// This PC's answer, then each distro's, in order:
    /// - running, answered: its tools, problems and looks, without a login
    ///   not set up there or a source Linux can't read at all; with the
    ///   deadline passed, a login still reading took too long;
    /// - stopped, with a kept answer: its tools and looks, each tool and each
    ///   login with a problem `notRunning` (the app says since when);
    /// - a failed run: a kept answer's tools and looks, each tool `failed`;
    ///   with none kept, one problem and look for the distro;
    /// - stopped with nothing kept: nothing.
    ///
    /// Each side already spread its problems over its groups; this doesn't again.
    public static func merge(_ windows: HudMonitor.Answer, with distros: [WslDistro]) -> HudMonitor.Answer {
        let parts = distros.compactMap(part(of:))
        guard !parts.isEmpty else { return windows }
        let named = parts.filter { $0.hud }.count > 1
        var tools = windows.reading.tools, problems = windows.problems, looks = windows.looks
        var readAt = windows.readAt
        for part in parts {
            let suffix = named ? " · WSL \(part.distro)" : " · WSL"
            tools += part.tools
            problems += part.problems
            looks += part.looks.map { part.hud ? HudMonitor.Look(id: $0.id, name: $0.name + suffix, light: $0.light, dark: $0.dark) : $0 }
            if let at = part.readAt { readAt = max(readAt ?? at, at) }
        }
        let worst = tools.flatMap(\.lines).map(\.status).reduce(windows.reading.worst) { rank($1) > rank($0) ? $1 : $0 }
        return HudMonitor.Answer(reading: HudReading(tools: tools, worst: worst), readAt: readAt, problems: problems, looks: looks)
    }

    /// What one distro adds, already renamed; `hud` when it comes from an
    /// answer, whose looks then say WSL.
    private struct Part {
        let distro: String
        let hud: Bool
        let tools: [HudReading.Tool]
        let problems: [HudMonitor.Problem]
        let looks: [HudMonitor.Look]
        let readAt: Date?
    }

    private static func part(of distro: WslDistro) -> Part? {
        let name = distro.name
        let answer = distro.reading?.hud
        if let failure = distro.failure {
            guard let answer else {
                let id = "wsl:\(name)"
                let grey = ProviderTokenLogs.hex(nil)
                return Part(distro: name, hud: false, tools: [], problems: [HudMonitor.Problem(id: id, kind: "failed", message: failure)],
                            looks: [HudMonitor.Look(id: id, name: "WSL \(name)", light: grey, dark: grey)], readAt: nil)
            }
            let tools = answer.reading.tools.map { renamed($0, in: name) }
            return Part(distro: name, hud: true, tools: tools,
                        problems: tools.map { HudMonitor.Problem(id: $0.id, kind: "failed", message: failure) },
                        looks: looks(of: answer, showing: answer.reading.tools, [], in: name), readAt: answer.readAt)
        }
        guard let answer else { return nil }
        let kept = answer.problems.filter { !($0.kind == "notSetUp" || ($0.kind == "failed" && $0.message.contains(unavailableOnLinux))) }
        let tools = answer.reading.tools.map { renamed($0, in: name) }
        let problems: [HudMonitor.Problem]
        if distro.running {
            let timedOut = distro.reading?.timedOut == true
            problems = kept.map { problem in
                timedOut && problem.kind == "reading"
                    ? HudMonitor.Problem(id: id(problem.id, in: name), kind: "failed", message: tookTooLong)
                    : HudMonitor.Problem(id: id(problem.id, in: name), kind: problem.kind, message: problem.message)
            }
        } else {
            var ids = tools.map(\.id)
            for problem in kept where !ids.contains(id(problem.id, in: name)) { ids.append(id(problem.id, in: name)) }
            problems = ids.map { HudMonitor.Problem(id: $0, kind: "notRunning", message: "") }
        }
        return Part(distro: name, hud: true, tools: tools, problems: problems,
                    looks: looks(of: answer, showing: answer.reading.tools, kept, in: name), readAt: answer.readAt)
    }

    private static func renamed(_ tool: HudReading.Tool, in distro: String) -> HudReading.Tool {
        HudReading.Tool(id: id(tool.id, in: distro), group: tool.group, via: tool.via.map { id($0, in: distro) }, lines: tool.lines,
                        headline: tool.headline, others: tool.others, outUntil: tool.outUntil, runningHot: tool.runningHot,
                        readAt: tool.readAt, notes: tool.notes, tier: tool.tier, signedOut: tool.signedOut)
    }

    /// The answer's looks for what the distro shows (a tool, the login it
    /// was read through, a kept problem), renamed.
    private static func looks(of answer: HudMonitor.Answer, showing tools: [HudReading.Tool], _ problems: [HudMonitor.Problem],
                              in distro: String) -> [HudMonitor.Look] {
        let shown = Set(tools.map(\.id) + tools.compactMap(\.via) + problems.map(\.id))
        return answer.looks.filter { shown.contains($0.id) }
            .map { HudMonitor.Look(id: id($0.id, in: distro), name: $0.name, light: $0.light, dark: $0.dark) }
    }

    private static func rank(_ status: String) -> Int {
        ["healthy", "warning", "critical", "depleted"].firstIndex(of: status) ?? 0
    }
}
