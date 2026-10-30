import Foundation
import Monitoring
import Providers
import Quotas

/// The HUD's limits on this PC: ClaudeBar's own `QuotaMonitor` over every
/// provider ClaudeBar finds here, made as the Mac makes them (the bundled
/// definitions and the person's own, on one `Engine`), with the person's
/// settings as ClaudeBar keeps them (`ClaudeBarSettings`).
///
/// The first answer starts its background refresh; every answer is read
/// from the snapshots the monitor holds then, so the HUD never waits on a
/// tool. *Refresh* refreshes every login first.
@MainActor
public final class HudMonitor {
    /// A login in the lineup the HUD has no fresh numbers for, and why:
    /// `reading` (not read yet), `notSetUp` (no tool or sign-in on this PC),
    /// `signedOut`, or `failed` (its last refresh failed; any numbers it
    /// showed before stay in the reading). `message` is the text a person
    /// reads: what setting it up takes, or what failed.
    public struct Problem: Equatable, Sendable, Encodable {
        public let id: String
        public let kind: String
        public let message: String
    }

    /// How the app draws a login: the name the lineup prints and its
    /// product's colour in a light and a dark theme (`#RRGGBB`). A group
    /// (`omp/Codex`) is drawn as the product it names.
    public struct Look: Equatable, Sendable, Encodable {
        public let id: String
        public let name: String
        public let light: String
        public let dark: String
    }

    public struct Answer: Equatable, Sendable {
        public let reading: HudReading
        /// When the newest numbers in the reading were read.
        public let readAt: Date?
        public let problems: [Problem]
        /// One for each login in the reading or the problems, in lineup order.
        public let looks: [Look]

        /// `{reading, readAt, problems, looks}`, every date in seconds since 1970.
        public func json() throws -> [String: Any] {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            func object(_ value: some Encodable) throws -> Any {
                try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
            }
            return ["reading": try object(reading), "readAt": readAt.map { $0.timeIntervalSince1970 } ?? NSNull(),
                    "problems": try object(problems), "looks": try object(looks)]
        }
    }

    public let monitor: QuotaMonitor
    private let interval: Duration
    /// Every provider ClaudeBar knows, for the colours of the products an aggregator's groups name.
    private let definitions: [ProviderDefinition]
    private var loop: Task<Void, Never>?
    /// Logins found with no tool or sign-in to read with, at the last refresh.
    private var notReady: Set<String> = []

    /// `interval` is the background cadence, ClaudeBar's default 10 minutes
    /// unless given; the monitor never polls faster than once a minute.
    public init(monitor: QuotaMonitor, interval: Duration = .seconds(600),
                definitions: [ProviderDefinition] = Array(ProviderFactory.builtInDefinitions.values)) {
        self.monitor = monitor
        self.interval = interval
        self.definitions = definitions
    }

    /// Every provider ClaudeBar finds on this PC, on this PC's platform.
    public convenience init(settings: ClaudeBarSettings = ClaudeBarSettings()) {
        let engine = Engine(settings: settings)
        let definitions = ProviderCatalog().detect()
        let providers = Providers(ProviderFactory.make(definitions, engine: engine), settings: settings,
                                  make: { ProviderFactory.make($0, engine: engine) })
        self.init(monitor: QuotaMonitor(providers: providers, clock: SystemClock(), settingsRepository: settings,
                                        statusPolicy: { settings.statusPolicy() }),
                  definitions: definitions)
    }

    /// What the HUD shows now. The first call starts the background refresh.
    public func answer() -> Answer {
        start()
        return current()
    }

    /// Refreshes every login in the lineup now, then answers.
    public func refresh() async -> Answer {
        start()
        await monitor.refreshAll()
        await checkReadiness()
        return current()
    }

    /// Starts the background refresh of the whole lineup, once.
    private func start() {
        guard loop == nil else { return }
        let events = monitor.startMonitoring(interval: interval, providerIds: monitor.lineup.map(\.id))
        loop = Task { [weak self] in
            for await event in events {
                guard case .refreshed = event else { continue }
                await self?.checkReadiness()
            }
        }
    }

    /// Which logins without an error have nothing to read with: the monitor
    /// skips them without a word, as ClaudeBar's popover does, and keeps any
    /// numbers they showed before.
    private func checkReadiness() async {
        var found: Set<String> = []
        for login in monitor.lineup where login.lastError == nil {
            if let product = monitor.product(of: login), await !product.isAvailable(login) { found.insert(login.id) }
        }
        notReady = found
    }

    private func current() -> Answer {
        let lineup = monitor.lineup
        // Each login under its lineup id, so two logins of one product are two tools.
        let snapshots = lineup.compactMap { login in
            monitor.usage(of: login).map { UsageSnapshot(providerId: login.id, quotas: $0.quotas, capturedAt: $0.capturedAt) }
        }
        let reading = HudReading(snapshots: snapshots, policy: monitor.statusPolicy)
        let problems = lineup.compactMap(problem(of:))
        let shown = Set(snapshots.map(\.providerId) + problems.map(\.id))
        let looks = lineup.filter { shown.contains($0.id) }.map { login in
            Look(id: login.id, name: monitor.lineupName(of: login),
                 light: ProviderTokenLogs.hex(login.look.color?.light), dark: ProviderTokenLogs.hex(login.look.color?.dark))
        }
        return Answer(reading: reading, readAt: snapshots.map(\.capturedAt).max(),
                      problems: Self.spread(problems, over: reading),
                      looks: Self.looks(looks, for: reading, definitions: definitions))
    }

    private func problem(of login: Account) -> Problem? {
        // What setting it up takes; a definition that says nothing has its title, *Set up <name>*.
        let setup = {
            let notice = self.monitor.setupNotice(of: login)
            return notice.text.isEmpty ? notice.title : notice.text
        }
        if let error = login.lastError {
            switch error as? UsageError {
            // Not set up is left out of the HUD; a CLI gone while its numbers stay makes them stale, a failure.
            case .cliNotFound? where monitor.usage(of: login) == nil: return Problem(id: login.id, kind: "notSetUp", message: setup())
            case .authenticationRequired?, .sessionExpired?: return Problem(id: login.id, kind: "signedOut", message: setup())
            default:
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return Problem(id: login.id, kind: "failed", message: message)
            }
        }
        if notReady.contains(login.id) {
            // As with a CLI gone: nothing to read with, so numbers it still has are stale.
            return Problem(id: login.id, kind: monitor.usage(of: login) == nil ? "notSetUp" : "failed", message: setup())
        }
        guard monitor.usage(of: login) == nil else { return nil }
        return Problem(id: login.id, kind: "reading", message: "")
    }

    /// The lineup's looks, each login's groups after it: a group in the
    /// colours of the product whose name it starts with (`Codex`, `Claude ·
    /// work`), or the login's own when ClaudeBar knows no such product, and
    /// named as its section with a long account shortened as the Mac's menu
    /// bar shortens it (omp's `menuBarTitle`: past 8 characters, 7 and "…").
    static func looks(_ lineup: [Look], for reading: HudReading, definitions: [ProviderDefinition]) -> [Look] {
        lineup.flatMap { login in
            [login] + reading.tools.filter { $0.via == login.id }.compactMap { tool -> Look? in
                guard let group = tool.group else { return nil }
                var parts = group.components(separatedBy: " · ")
                let product = definitions.first { $0.profile.name == parts[0] && $0.profile.look.color != nil }?.profile.look.color
                parts = [parts[0]] + parts.dropFirst().map { $0.count > 8 ? String($0.prefix(7)) + "…" : $0 }
                return Look(id: tool.id, name: parts.joined(separator: " · "),
                            light: product.map { ProviderTokenLogs.hex($0.light) } ?? login.light,
                            dark: product.map { ProviderTokenLogs.hex($0.dark) } ?? login.dark)
            }
        }
    }

    /// A login's problem is each of its groups' while it has their numbers:
    /// they were read together, so they're stale together.
    static func spread(_ problems: [Problem], over reading: HudReading) -> [Problem] {
        problems.flatMap { problem in
            let tools = reading.tools.filter { $0.id == problem.id || $0.via == problem.id }
            return tools.isEmpty ? [problem] : tools.map { Problem(id: $0.id, kind: problem.kind, message: problem.message) }
        }
    }
}
