import ClaudeBarShared
import Foundation

/// Each WSL distro's tools on the HUD (design, *The HUD, Limits and
/// Settings*): the running distros are probed at the HUD's cadence, and each
/// one's last answer is merged after this PC's, so `cbw_hud_reading` keeps
/// its shape. A distro that stops keeps its last numbers, `notRunning`.
@MainActor
public final class WslHud {
    /// What the app keeps for a distro in `app.json`: the switch, once the
    /// person sets it, and the last reading, for while it isn't running.
    public struct Kept: Equatable, Sendable {
        public let on: Bool?
        public let reading: ProbeReading?
        public let answeredAt: Date?
        public init(on: Bool?, reading: ProbeReading?, answeredAt: Date?) {
            self.on = on
            self.reading = reading
            self.answeredAt = answeredAt
        }
    }

    /// A distro read since the start: its last answer, or why the last run failed.
    private struct Read {
        var reading: ProbeReading?
        var answeredAt: Date?
        var failure: String?
    }

    private let probe: any WslProbing
    private let list: @Sendable (_ runningOnly: Bool) async -> [String]?
    private let interval: Duration
    private let now: @Sendable () -> Date
    private var kept: [String: Kept] = [:]
    private var read: [String: Read] = [:]
    private var probing: Set<String> = []
    /// The last `-l -q`, readable distros only; nil when it failed or before it came.
    private var distros: [String]?
    private var running: Set<String> = []
    private var runningListedAt: Date?
    private var relisting = false
    private var loop: Task<Void, Never>?
    /// Work started and not yet done, for `settled()`.
    private var pending: [UUID: Task<Void, Never>] = [:]

    /// The running list is asked again when an answer finds it older than this.
    static let runningListAge: TimeInterval = 30

    public init(probe: any WslProbing = WslProbe(),
                list: @escaping @Sendable (_ runningOnly: Bool) async -> [String]? = WslHud.list,
                interval: Duration = .seconds(600), now: @escaping @Sendable () -> Date = Date.init) {
        self.probe = probe
        self.list = list
        self.interval = interval
        self.now = now
    }

    public func configure(_ kept: [String: Kept]) {
        self.kept = kept
    }

    /// `app.json`'s `wsl`: `{"<distro>": {"on", "answeredAt", "reading"}}`.
    /// A distro whose reading doesn't decode (from another version) keeps its switch.
    public static func kept(fromJSON text: String) -> [String: Kept] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
        var kept: [String: Kept] = [:]
        for (distro, value) in object {
            guard let entry = value as? [String: Any] else { continue }
            let reading = entry["reading"].flatMap { reading -> ProbeReading? in
                guard !(reading is NSNull), let data = try? JSONSerialization.data(withJSONObject: reading) else { return nil }
                return try? ProbeReading.decoder().decode(ProbeReading.self, from: data)
            }
            kept[distro] = Kept(on: entry["on"] as? Bool, reading: reading,
                                answeredAt: (entry["answeredAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        return kept
    }

    /// This PC's answer with each distro's; the first call starts the probes' cadence.
    public func answer(merging windows: HudMonitor.Answer) -> HudMonitor.Answer {
        start()
        if let listedAt = runningListedAt, now().timeIntervalSince(listedAt) > Self.runningListAge, !relisting {
            relisting = true
            track { [list] in
                let found = await list(true)
                self.running = Set(found ?? [])
                self.runningListedAt = self.now()
                self.relisting = false
            }
        }
        let shown = (distros ?? []).filter { kept[$0]?.on != false }.map { name in
            let last = read[name]
            return WslDistro(name: name, running: running.contains(name),
                             reading: last?.reading ?? kept[name]?.reading,
                             answeredAt: last?.answeredAt ?? kept[name]?.answeredAt,
                             failure: last?.failure)
        }
        return WslLineup.merge(windows, with: shown)
    }

    /// Probes every running distro that isn't off, now; doesn't wait for them.
    public func refresh() {
        track { await self.refreshNow() }
    }

    /// The reply's `wsl`: `{installed, distros: [{name, running, on, probing,
    /// answeredAt, reading, error}]}`.
    public func json() throws -> [String: Any] {
        let encoder = ProbeReading.encoder()
        let rows = try (distros ?? []).map { name -> [String: Any] in
            let last = read[name]
            let reading = last?.reading ?? kept[name]?.reading
            let answeredAt = last?.answeredAt ?? kept[name]?.answeredAt
            return [
                "name": name,
                "running": running.contains(name),
                "on": kept[name]?.on.map { $0 as Any } ?? NSNull(),
                "probing": probing.contains(name),
                "answeredAt": answeredAt.map { $0.timeIntervalSince1970 } ?? NSNull(),
                "reading": try reading.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) } ?? NSNull(),
                "error": last?.failure ?? NSNull(),
            ]
        }
        return ["installed": distros != nil, "distros": rows]
    }

    /// Waits for every list and run started so far, and any they start.
    func settled() async {
        while let task = pending.values.first { await task.value }
    }

    /// Starts the cadence once: a refresh now, then one every `interval`.
    private func start() {
        guard loop == nil else { return }
        refresh()
        loop = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.refresh()
            }
        }
    }

    private func refreshNow() async {
        let list = self.list
        async let all = list(false)
        async let up = list(true)
        let (found, foundRunning) = await (all, up)
        distros = found.map(WslCommand.readable)
        running = Set(foundRunning ?? [])
        runningListedAt = now()
        for distro in distros ?? [] where running.contains(distro) && kept[distro]?.on != false && !probing.contains(distro) {
            probing.insert(distro)
            track { [probe] in
                let result = await probe.run(distro: distro, logsOnly: false)
                self.probing.remove(distro)
                var last = self.read[distro] ?? Read(reading: self.kept[distro]?.reading, answeredAt: self.kept[distro]?.answeredAt)
                switch result {
                case .success(let reading):
                    last = Read(reading: reading, answeredAt: self.now(), failure: nil)
                case .failure(let failure):
                    last.failure = failure.message
                }
                self.read[distro] = last
            }
        }
    }

    /// Runs `work` on the main actor, kept in `pending` until it's done.
    private func track(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        pending[id] = Task {
            await work()
            self.pending[id] = nil
        }
    }

    /// `wsl.exe -l -q`, or `-l --running -q`; nil when WSL isn't there or the list fails.
    public nonisolated static func list(runningOnly: Bool) async -> [String]? {
        await withCheckedContinuation { continuation in
            Thread {
                let output = SystemWslProcesses().run(WslProbe.systemWsl, WslCommand.list(runningOnly: runningOnly),
                                                      timeout: WslProbe.stepTimeout)
                guard let output, output.exit == 0 else { return continuation.resume(returning: nil) }
                continuation.resume(returning: WslCommand.distros(in: output.stdout))
            }.start()
        }
    }

    /// Before an uninstall: `--end all` in each running distro, 20 s in all,
    /// inside the 30 s Velopack gives the uninstall hook. The distros swept,
    /// or -1 when `wsl.exe` couldn't list them.
    public nonisolated static func endAll() -> Int32 {
        endAll(processes: SystemWslProcesses(), wsl: WslProbe.systemWsl, probe: WslProbe.bundled, budget: 20)
    }

    nonisolated static func endAll(processes: any WslProcesses, wsl: URL, probe: URL, budget: TimeInterval) -> Int32 {
        let end = Date().addingTimeInterval(budget)
        func left(atMost seconds: Int) -> Duration? {
            let remaining = end.timeIntervalSinceNow
            return remaining > 0 ? .milliseconds(Int(min(remaining, Double(seconds)) * 1000)) : nil
        }
        guard let first = left(atMost: 5),
              let listed = processes.run(wsl, WslCommand.list(runningOnly: true), timeout: first), listed.exit == 0 else { return -1 }
        let windowsPath = probe.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? probe.path
        var swept: Int32 = 0
        for distro in WslCommand.readable(WslCommand.distros(in: listed.stdout)) {
            guard let step = left(atMost: 5),
                  let path = processes.run(wsl, WslCommand.wslpath(distro: distro, path: windowsPath), timeout: step), path.exit == 0
            else { continue }
            let linux = WslCommand.text(in: path.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let step = left(atMost: 10),
                  let ended = processes.run(wsl, WslCommand.end(distro: distro, probe: linux, target: "all"), timeout: step),
                  ended.exit == 0 else { continue }
            swept += 1
        }
        return swept
    }
}
