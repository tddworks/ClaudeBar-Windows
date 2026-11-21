#if os(Linux)
import Foundation
import Glibc

/// Whether the probe can count in the zone the app sent (design, *The time
/// zone*). ClaudeBar's `LinuxTimeZone` takes `TZ` only when its file is under
/// `/usr/share/zoneinfo`, else the OS's offset, fixed; Foundation falls back to
/// `/etc/localtime` for a name it doesn't know; and a name like `GMT+0900`
/// stops the process. None of that says so, so the probe checks first.
public enum ZoneCheck {
    public enum Verdict: Equatable, Sendable {
        /// No TZ: the distro's own zone, as every probe before phase 2.
        case none
        case accepted(String)
        /// Why, for the diagnostics.
        case refused(String)
    }

    public static func check(_ tz: String?, zoneinfo: String = "/usr/share/zoneinfo") -> Verdict {
        guard let tz, !tz.isEmpty else { return .none }
        let parts = tz.split(separator: "/", omittingEmptySubsequences: false)
        guard !tz.hasPrefix(":"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return .refused("TZ \(tz) isn't a zone name")
        }
        let file = zoneinfo + "/" + tz
        var info = stat()
        guard stat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return .refused("no time zone data for \(tz) (\(file))")
        }
        guard TimeZone(identifier: tz)?.identifier == tz else { return .refused("no time zone named \(tz)") }
        return .accepted(tz)
    }

    /// Checks `TZ` and, when refused, unsets it before anything reads a zone
    /// (Foundation keeps the first zone it reads), so the HUD, the CLIs and
    /// ClaudeBar all count in the distro's own.
    public static func apply() -> Verdict {
        let verdict = check(ProcessInfo.processInfo.environment["TZ"])
        if case .refused = verdict {
            unsetenv("TZ")
            tzset()
        }
        return verdict
    }
}
#endif
