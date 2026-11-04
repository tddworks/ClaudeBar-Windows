import Foundation

/// Whether a WSL source and a Windows one are the same place
/// (docs/plans/2026-11-03-wsl-design.md, Folders shared with Windows). Both
/// sides in Windows form, normalized: the `\\?\` prefix
/// `GetFinalPathNameByHandleW` returns removed (`\\?\UNC\` becomes `\\`),
/// `\\wsl$\` read as `\\wsl.localhost\`, case ignored, `\` and `/` the same,
/// no trailing separator.
///
/// A credential root is shared only when it's the same place as one of
/// Windows' credential roots: an account nested in the folder Windows reads
/// (`.claude\wsl` in `.claude`) is another login. A log root is shared when
/// it overlaps one of Windows' log roots, one inside the other by whole
/// names: records are read as a folder tree.
public enum SharedRoots {
    /// One of the probe's roots, mapped to Windows.
    public struct WslRoot: Equatable, Sendable {
        public let kind: ProbeReading.RootKind
        /// The root in Windows form, or nil when it's under a drive mount that couldn't be mapped.
        public let windowsPath: String?

        public init(kind: ProbeReading.RootKind, windowsPath: String?) {
            self.kind = kind
            self.windowsPath = windowsPath
        }
    }

    public static func normalized(_ path: String) -> String {
        var path = path.replacingOccurrences(of: "/", with: "\\")
        if path.hasPrefix(#"\\?\UNC\"#) {
            path = #"\\"# + path.dropFirst(8)
        } else if path.hasPrefix(#"\\?\"#) {
            path = String(path.dropFirst(4))
        }
        if path.lowercased().hasPrefix(#"\\wsl$\"#) { path = #"\\wsl.localhost\"# + path.dropFirst(7) }
        return path.lowercased()
    }

    /// The same file or folder, by whole names.
    public static func isSame(_ a: String, _ b: String) -> Bool {
        let x = names(a)
        return !x.isEmpty && x == names(b)
    }

    /// The same place, or one inside the other, by whole names.
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        let x = names(a), y = names(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.starts(with: y) || y.starts(with: x)
    }

    /// Each WSL root left out: a credential root the same place as one of
    /// the provider's Windows credential roots, a log root overlapping one
    /// of its Windows log roots, or one that couldn't be checked. Counting
    /// nothing from a source beats counting it twice.
    public static func skips(provider: String, roots: [WslRoot], windows: ProviderRoots?) -> [ProbeReading.Skip] {
        var skips: [ProbeReading.Skip] = []
        for root in roots {
            let skip: ProbeReading.Skip?
            if let path = root.windowsPath {
                let match = switch root.kind {
                case .credentials: windows?.credentials.first { isSame(path, $0) }
                case .logs: windows?.logs.first { overlaps(path, $0) }
                }
                skip = match.map { .init(provider: provider, kind: root.kind, windowsPath: $0, reason: .shared) }
            } else {
                skip = .init(provider: provider, kind: root.kind, windowsPath: nil, reason: .uncheckable)
            }
            if let skip, !skips.contains(skip) { skips.append(skip) }
        }
        return skips
    }

    /// A path's names, normalized; a UNC path's server and share are names too.
    private static func names(_ path: String) -> [String] {
        normalized(path).split(separator: "\\").map(String.init)
    }
}
