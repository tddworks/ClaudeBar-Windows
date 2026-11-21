import ClaudeBarShared
import DataSources
import Diagnostics
import Foundation
import Leaderboard
import Providers
import Quotas

/// The distros' days for the Leaderboard (docs/plans/2026-11-03-wsl-design.md,
/// The Leaderboard (phase 2)): each distro's kept days as they count now
/// (`WslKeptDays.current`), as plain `LoginDays`. The hourly uploader asks
/// `fresh`: first a `--logs-only` run in each running distro that's on, so
/// its kept days are new; the app's own uploads and its preview read the
/// kept days as the HUD's runs left them, so nobody waits on a distro.
@MainActor
public final class WslDays {
    private let fresh: Bool
    private let probe: any WslProbing
    private let kept: WslKeptDays
    private let list: @Sendable (_ runningOnly: Bool) async -> [String]?
    private let switches: @Sendable () -> [String: Bool]
    private let zone: @Sendable () -> TimeZone
    private let now: @Sendable () -> Date
    private let windows: @Sendable () -> [ProviderRoots]
    private let log: @Sendable (String) -> Void

    public init(fresh: Bool = false, probe: any WslProbing = WslProbe(), kept: WslKeptDays = WslKeptDays(),
                list: @escaping @Sendable (_ runningOnly: Bool) async -> [String]? = WslHud.list,
                switches: @escaping @Sendable () -> [String: Bool] = WslDays.switches,
                zone: @escaping @Sendable () -> TimeZone = DataSources.timeZone,
                now: @escaping @Sendable () -> Date = Date.init,
                windows: @escaping @Sendable () -> [ProviderRoots] = WslDays.windowsRoots,
                log: @escaping @Sendable (String) -> Void = WslDays.log) {
        self.fresh = fresh
        self.probe = probe
        self.kept = kept
        self.list = list
        self.switches = switches
        self.zone = zone
        self.now = now
        self.windows = windows
        self.log = log
    }

    /// This PC's log roots per provider, as `WslProbe` writes them for a run:
    /// what a kept root this PC reads now is told by.
    public nonisolated static func windowsRoots() -> [ProviderRoots] {
        WslWindowsRoots.make(distro: "", definitions: ProviderCatalog().detect(),
                             homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                             environment: { ProcessInfo.processInfo.environment[$0] }).providers
    }

    /// Each distro's switch, as the app keeps it in
    /// `%LOCALAPPDATA%\ClaudeBar\app.json`.
    public nonisolated static func switches() -> [String: Bool] {
        switches(appJSON: WslProbe.folder.deletingLastPathComponent().appendingPathComponent("app.json"))
    }

    /// The switches set in `appJSON`'s `wsl` (`WslHud.kept(fromJSON:)`); none
    /// when it's missing or doesn't read.
    nonisolated static func switches(appJSON: URL) -> [String: Bool] {
        guard let data = FileManager.default.contents(atPath: appJSON.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wsl = object["wsl"], let text = try? JSONSerialization.data(withJSONObject: wsl) else { return [:] }
        return WslHud.kept(fromJSON: String(decoding: text, as: UTF8.self)).compactMapValues(\.on)
    }

    public nonisolated static func log(_ line: String) {
        AppLog.network.info(line)
    }

    /// The providers the kept days have.
    public var providers: Set<String> {
        Set(kept.all().flatMap { $0.days.map(\.provider) })
    }

    /// The kept days as they count now, of `range` as `calendar` labels it;
    /// in fresh mode after a `--logs-only` run in each running distro that's
    /// on, each under its own mutex. A distro that can't be read, stopped,
    /// switched off or removed keeps the days it had; in fresh mode the log
    /// says so for each one with a day in `range`.
    public func days(in range: DateRange, calendar: Calendar) async -> [LoginDays] {
        // Why a distro wasn't read in fresh mode; nil when it was, or when not fresh.
        var unread: (String) -> String? = { _ in nil }
        if fresh {
            if let running = await list(true) {
                let on = switches()
                let distros = WslCommand.readable(running).filter { on[$0] != false }
                await withTaskGroup(of: (String, WslFailure?).self) { [probe] group in
                    for distro in distros {
                        group.addTask {
                            if case .failure(let failure) = await probe.run(distro: distro, logsOnly: true) { return (distro, failure) }
                            return (distro, nil)
                        }
                    }
                    for await (distro, failure) in group {
                        if let failure { log("Leaderboard: WSL \(distro): \(failure.message); its kept days go") }
                    }
                }
                unread = { distro in distros.contains(distro) ? nil : on[distro] == false ? "switched off" : "not running" }
            } else {
                unread = { _ in "the running distros couldn't be listed" }
            }
        }
        let counted = WslKeptDays.current(kept.all(), zone: WslZone.name(for: zone(), at: now()), windows: windows())
        for line in counted.leftOut { log("Leaderboard: " + line) }
        return counted.entries.flatMap { entry -> [LoginDays] in
            let logins = WslKeptDays.logins([entry], in: range, calendar: calendar)
            if !logins.isEmpty, let why = unread(entry.distro) { log("Leaderboard: WSL \(entry.distro): \(why); its kept days go") }
            return logins
        }
    }
}
