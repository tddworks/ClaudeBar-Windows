#if os(Linux)
import ClaudeBarShared
import Foundation
import Glibc
import Providers

/// The sources the probe leaves to Windows (design, *Folders shared with
/// Windows*): each provider's roots, expanded in the distro as the app
/// expands its own, resolved with `realpath`, put in Windows form and matched
/// against the same provider's roots in the app's file. A root that doesn't
/// exist reads nothing, so it's neither kept nor skipped.
public enum LinuxRoots {
    public struct Result: Equatable, Sendable {
        public let skipped: [ProbeReading.Skip]
        public let diagnostics: [String]
    }

    public static func skips(definitions: [ProviderDefinition], windows: WindowsRoots, homeDirectory: URL,
                             environment: @escaping @Sendable (String) -> String?, rule: DriveRule,
                             wslpath: (String) -> String?) -> Result {
        var skipped: [ProbeReading.Skip] = []
        var diagnostics: [String] = []
        for definition in definitions {
            let roots = ProviderRoots.of(definition, homeDirectory: homeDirectory, environment: environment)
            var wslRoots: [SharedRoots.WslRoot] = []
            for (kind, paths) in [(ProbeReading.RootKind.credentials, roots.credentials), (.logs, roots.logs)] {
                for path in paths {
                    guard let resolved = resolved(path) else { continue }
                    let windowsPath = WindowsPath.of(resolved, rule: rule, distro: windows.distro, wslpath: wslpath)
                    if windowsPath == nil {
                        let why = if case .guess = rule {
                            "the drive mounts couldn't be read, and it's under a guessed drive"
                        } else {
                            "its drive mount has no path= and wslpath -w couldn't map it"
                        }
                        diagnostics.append("couldn't check \(definition.id)'s \(kind.rawValue) root \(resolved) against Windows: \(why)")
                    }
                    wslRoots.append(SharedRoots.WslRoot(kind: kind, windowsPath: windowsPath))
                }
            }
            let theirs = windows.providers.first { $0.provider == definition.id }
            skipped += SharedRoots.skips(provider: definition.id, roots: wslRoots, windows: theirs)
        }
        return Result(skipped: skipped, diagnostics: diagnostics)
    }

    /// The path with every symlink followed, or nil when it doesn't exist.
    static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
#endif
