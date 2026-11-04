import Foundation
import Leaderboard

/// What `claudebar-probe` answers from inside a WSL distro, and the app
/// reads on Windows (docs/plans/2026-11-03-wsl-design.md, The probe): one
/// type, encoded by the probe and decoded by the app from this file, so the
/// two can't disagree on a field. tests/wsl-probe.json is a sample both
/// sides read.
public struct ProbeReading: Codable, Equatable, Sendable {
    /// What a source is to its provider: where its login is read from, or
    /// where its usage records are.
    public enum RootKind: String, Codable, Sendable { case credentials, logs }

    /// Why a source was left out: Windows reads the same place, or the
    /// probe couldn't map it to a Windows path to check (it fails closed).
    public enum SkipReason: String, Codable, Sendable { case shared, uncheckable }

    /// A tool found in the distro.
    public struct Tool: Codable, Equatable, Sendable {
        /// The provider's id (`claude`).
        public let id: String
        /// Where its CLI is, or nil when only its logs were found.
        public let cli: String?
        /// Whether its usage records were found.
        public let logs: Bool

        public init(id: String, cli: String?, logs: Bool) {
            self.id = id
            self.cli = cli
            self.logs = logs
        }
    }

    /// A source left out (design, Folders shared with Windows).
    public struct Skip: Codable, Equatable, Sendable {
        public let provider: String
        public let kind: RootKind
        /// The Windows root it's the same place as, or nil when it couldn't be checked.
        public let windowsPath: String?
        public let reason: SkipReason

        public init(provider: String, kind: RootKind, windowsPath: String?, reason: SkipReason) {
            self.provider = provider
            self.kind = kind
            self.windowsPath = windowsPath
            self.reason = reason
        }
    }

    /// Whether the variables the definitions name were read from the
    /// person's login shell (design, The environment).
    public struct EnvironmentImport: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case imported, failed }

        public let state: State
        /// The names it set, never their values.
        public let names: [String]
        /// Why it failed, when it did.
        public let reason: String?

        public init(state: State, names: [String], reason: String?) {
            self.state = state
            self.names = names
            self.reason = reason
        }
    }

    /// The client's version (`ClientVersion`), so the app can refuse a
    /// probe of another version.
    public let version: String
    /// The HUD's answer, exactly what `cbw_hud_reading` returns for this PC;
    /// nil with `--logs-only`.
    public let hud: HudMonitor.Answer?
    /// ClaudeBar's own days, made in the probe by `DailyTokens.summed` with
    /// the distro's calendar: day labels and counts, never dates.
    public let days: [DailyTokens]
    /// Each tool found, and where.
    public let tools: [Tool]
    /// Each source left out as shared with Windows, or as one it couldn't check.
    public let skipped: [Skip]
    /// The distro's time zone (`Asia/Seoul`).
    public let timeZone: String
    /// The deadline passed before every login was read: the HUD is as read
    /// by then, those still reading marked `reading`.
    public let timedOut: Bool
    public let environmentImport: EnvironmentImport
    /// What a person helping would want to know: a fallback taken, a path
    /// that couldn't be mapped.
    public let diagnostics: [String]

    public init(version: String, hud: HudMonitor.Answer?, days: [DailyTokens], tools: [Tool], skipped: [Skip],
                timeZone: String, timedOut: Bool, environmentImport: EnvironmentImport, diagnostics: [String]) {
        self.version = version
        self.hud = hud
        self.days = days
        self.tools = tools
        self.skipped = skipped
        self.timeZone = timeZone
        self.timedOut = timedOut
        self.environmentImport = environmentImport
        self.diagnostics = diagnostics
    }
}

extension ProbeReading {
    /// How the probe writes its answer and the app reads it: dates in
    /// seconds since 1970, as every reply over the C interface has them.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
