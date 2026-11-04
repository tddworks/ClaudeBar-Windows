import Foundation

/// How a run's processes are found again (design, *The marker*):
/// `CLAUDEBAR_WSL_RUN=<id>`, set by `env` before the probe is exec'd, so it's
/// in `/proc/<pid>/environ` of the probe and of everything it starts.
public enum RunMarker {
    public static let name = "CLAUDEBAR_WSL_RUN"

    /// Whose processes `--end` ends: one run's, or every run's.
    public enum Target: Equatable, Sendable {
        case run(String)
        case all
    }

    /// The marker's value in an environ file's NUL-separated `NAME=value`
    /// entries, matched by its whole name. Nil without one, as in a zombie's
    /// empty environ.
    public static func value(inEnviron environ: Data) -> String? {
        let prefix = Array("\(name)=".utf8)
        for entry in environ.split(separator: 0) where entry.starts(with: prefix) {
            return String(decoding: entry.dropFirst(prefix.count), as: UTF8.self)
        }
        return nil
    }

    public static func matches(_ environ: Data, _ target: Target) -> Bool {
        guard let value = value(inEnviron: environ) else { return false }
        switch target {
        case .run(let id): return value == id
        case .all: return true
        }
    }

    /// A run id as the app makes one: 32 lowercase hex digits.
    public static func isRunId(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
