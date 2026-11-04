#if os(Linux)
import ClaudeBarShared
import DataSources
import Foundation
import Glibc
import Leaderboard
import Providers
import Quotas

/// One run of `--json` or `--logs-only` (design, *The probe*), in the plan's
/// order: the drives, `PATH`, the environment import, the roots, the HUD
/// raced against the deadline, the days whole, then the answer.
@MainActor
public enum Probe {
    /// Why a run stops without an answer: `claudebar-probe: <reason>`, and its exit code.
    public struct Stop: Error {
        public let code: Int32
        public let reason: String
    }

    public static func run(_ arguments: ProbeArguments, marker id: String) async throws(Stop) -> ProbeReading {
        guard let rootsFile = arguments.windowsRoots else { throw Stop(code: 1, reason: "no --windows-roots") }
        var diagnostics: [String] = []

        // The drives, from the mount table, or guessed from wslpath's C drive.
        let rule: DriveRule
        if let mountinfo = readProcFile("/proc/self/mountinfo") {
            rule = .table(MountTable(mountinfo: String(decoding: mountinfo, as: UTF8.self)))
        } else if let cDrive = capture(["wslpath", "-u", "C:\\"]) {
            rule = .guess(cDrive: cDrive)
            diagnostics.append("/proc/self/mountinfo couldn't be read; drives guessed from wslpath's C drive, \(cDrive)")
        } else {
            rule = .guess(cDrive: "/mnt/c/")
            diagnostics.append("/proc/self/mountinfo couldn't be read, nor wslpath run; drives guessed at /mnt/<letter>")
        }

        // PATH without Windows' entries, before anything looks for a CLI or the shell runs.
        setenv("PATH", PathRule.withoutDrives(ProcessInfo.processInfo.environment["PATH"] ?? "", rule), 1)

        // The variables the definitions name, from the login shell, before any is expanded.
        let names = EnvironmentImport.names(usedBy: ProviderCatalog().detect())
        let environmentImport: ProbeReading.EnvironmentImport
        switch EnvironmentImport.importing(names: names, shell: ProcessInfo.processInfo.environment["SHELL"]) {
        case .values(let values):
            for (name, value) in values { setenv(name, value, 1) }
            environmentImport = .init(state: .imported, names: values.keys.sorted(), reason: nil)
        case .failed(let reason):
            environmentImport = .init(state: .failed, names: [], reason: reason)
        }

        // The roots the app reads, and the ones this distro reads.
        let windows: WindowsRoots
        do {
            windows = try JSONDecoder().decode(WindowsRoots.self, from: Data(contentsOf: URL(fileURLWithPath: rootsFile)))
        } catch {
            throw Stop(code: 1, reason: "couldn't read the Windows roots file \(rootsFile): \(error)")
        }
        let definitions = ProviderCatalog().detect()
        let roots = LinuxRoots.skips(definitions: definitions, windows: windows,
                                     homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                                     environment: { ProcessInfo.processInfo.environment[$0] }, rule: rule,
                                     wslpath: { capture(["wslpath", "-w", $0]) })
        diagnostics += roots.diagnostics
        let off = Set(roots.skipped.filter { $0.kind == .credentials }.map(\.provider))
        let except = Set(roots.skipped.filter { $0.kind == .logs }.map(\.provider))

        // The HUD, at most until the deadline.
        var hud: HudMonitor.Answer?
        var timedOut = false
        if arguments.mode == .json {
            (hud, timedOut) = await refreshed(HudMonitor(settings: ClaudeBarSettings(off: off)), deadline: arguments.deadline)
        }

        // The days, whole, after the refresh or the deadline.
        let calendar = DataSources.calendar()
        let logs = ProviderTokenLogs(except: except)
        let read = await logs.days(in: DateRange.last(arguments.days, endingOn: Date(), calendar: calendar))
        let days = DailyTokens.summed(read, providers: logs.providersWithLogs, calendar: calendar)

        return ProbeReading(version: ClientVersion.version, hud: hud, days: days,
                            tools: tools(hud: hud, days: days, definitions: definitions),
                            skipped: roots.skipped, timeZone: calendar.timeZone.identifier, timedOut: timedOut,
                            environmentImport: environmentImport, diagnostics: diagnostics)
    }

    /// The refresh raced against the deadline, as the spike does: the
    /// refresh's answer when it finishes first, else the answer as read by
    /// then, logins still reading marked `reading`.
    static func refreshed(_ hud: HudMonitor, deadline: Double) async -> (HudMonitor.Answer, Bool) {
        await withCheckedContinuation { continuation in
            let once = Once()
            Task { @MainActor in
                let answer = await hud.refresh()
                if once.take() { continuation.resume(returning: (answer, false)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(deadline))
                if once.take() { continuation.resume(returning: (hud.answer(), true)) }
            }
        }
    }

    /// Each provider the HUD found set up, with its CLI when it has one, in
    /// lineup order; then each provider with days, as logs. Not set up is
    /// `notSetUp`, or a failure that says Linux can't read that source at
    /// all (Antigravity's local server), as the lineup's merge reads it. A
    /// provider is one tool however many logins it has.
    static func tools(hud: HudMonitor.Answer?, days: [DailyTokens], definitions: [ProviderDefinition]) -> [ProbeReading.Tool] {
        let byId = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func definition(_ login: String) -> ProviderDefinition? {
            byId[login] ?? login.split(separator: ".", maxSplits: 1).first.flatMap { byId[String($0)] }
        }
        let withLogs = Set(days.map(\.provider))
        var order: [String] = []
        if let hud {
            let notFound = Set(hud.problems.filter {
                $0.kind == "notSetUp" || ($0.kind == "failed" && $0.message.contains(WslLineup.unavailableOnLinux))
            }.map(\.id))
            // Looks list every login shown, in lineup order; a group (`omp/Codex`) is its login's.
            for look in hud.looks where !look.id.contains("/") && !notFound.contains(look.id) {
                if let id = definition(look.id)?.id, !order.contains(id) { order.append(id) }
            }
        }
        order += withLogs.subtracting(order).sorted()
        return order.map { id in
            ProbeReading.Tool(id: id, cli: byId[id]?.cli.flatMap(DataSources.locate), logs: withLogs.contains(id))
        }
    }

    /// A short command's first line of output, or nil when it can't run or fails.
    static func capture(_ argv: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? nil : line
    }
}

/// The first of the two racers to finish answers; the other finds it taken.
@MainActor
private final class Once {
    private var taken = false
    func take() -> Bool {
        defer { taken = true }
        return !taken
    }
}
#endif
