/// The probe's command line (the plan's contract):
///
///     claudebar-probe --json --windows-roots <file> [--deadline <s>] [--days <n>]
///     claudebar-probe --logs-only --windows-roots <file> [--days <n>]
///     claudebar-probe --end <id>|all
public struct ProbeArguments: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// The HUD's answer after a refresh, and the days.
        case json
        /// The days only: no refresh, no CLI.
        case logsOnly
        /// End every process carrying a run's marker, or any run's.
        case end(RunMarker.Target)
    }

    /// Why a command line can't run, as `claudebar-probe: <reason>` says it.
    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    public let mode: Mode
    /// The app's roots file, a `WindowsRoots`; nil only with `--end`.
    public let windowsRoots: String?
    /// Seconds the refresh may take before the answer goes with what's read.
    public let deadline: Double
    /// The days of tokens to read, today the last.
    public let days: Int

    public init(mode: Mode, windowsRoots: String?, deadline: Double = 60, days: Int = 30) {
        self.mode = mode
        self.windowsRoots = windowsRoots
        self.deadline = deadline
        self.days = days
    }

    public static func parse(_ arguments: [String]) throws -> ProbeArguments {
        var modes: [Mode] = []
        var windowsRoots: String?
        var deadline = 60.0
        var days = 30
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": modes.append(.json)
            case "--logs-only": modes.append(.logsOnly)
            case "--end":
                guard let target = rest.popFirst() else { throw Invalid("--end needs a run id or all") }
                if target == "all" {
                    modes.append(.end(.all))
                } else {
                    guard RunMarker.isRunId(target) else { throw Invalid("--end needs a run id of 32 lowercase hex digits, or all") }
                    modes.append(.end(.run(target)))
                }
            case "--windows-roots":
                guard let file = rest.popFirst(), !file.isEmpty else { throw Invalid("--windows-roots needs a file") }
                windowsRoots = file
            case "--deadline":
                guard let seconds = rest.popFirst().flatMap(Double.init), seconds.isFinite, seconds > 0 else {
                    throw Invalid("--deadline needs a positive number of seconds")
                }
                deadline = seconds
            case "--days":
                guard let count = rest.popFirst().flatMap({ Int($0) }), count > 0 else {
                    throw Invalid("--days needs a positive whole number")
                }
                days = count
            default:
                throw Invalid("unknown option \(argument)")
            }
        }
        guard let mode = modes.first else { throw Invalid("no mode: give --json, --logs-only or --end <id|all>") }
        guard modes.count == 1 else { throw Invalid("more than one mode: give one of --json, --logs-only or --end") }
        switch mode {
        case .json, .logsOnly:
            guard windowsRoots != nil else { throw Invalid("\(mode == .json ? "--json" : "--logs-only") needs --windows-roots <file>") }
        case .end:
            break
        }
        return ProbeArguments(mode: mode, windowsRoots: windowsRoots, deadline: deadline, days: days)
    }
}
