import ClaudeBarShared
import Foundation
import Providers
import WinSDK

/// This PC's roots, per provider, for one probe run: the file the probe
/// compares its own roots with, to skip what both sides read (design,
/// *Folders shared with Windows*). Each root is expanded as ClaudeBar's
/// factory and token logs expand it, then resolved through symlinks and
/// junctions, so a WSL path into the folder a junction points at matches.
public enum WslWindowsRoots {
    /// Every definition's roots on this PC, each resolved where it exists.
    public static func make(distro: String, definitions: [ProviderDefinition], homeDirectory: URL,
                            environment: @escaping @Sendable (String) -> String?) -> WindowsRoots {
        let providers = definitions.map { definition in
            let roots = ProviderRoots.of(definition, homeDirectory: homeDirectory, environment: environment)
            return ProviderRoots(provider: roots.provider, credentials: roots.credentials.map(finalPath),
                                 logs: roots.logs.map(finalPath))
        }
        return WindowsRoots(version: ClientVersion.version, distro: distro, providers: providers)
    }

    /// Writes `windows-roots-<run>.json` in `folder`, a file of that run's
    /// own: the app and the uploader can probe two distros at once. Nothing
    /// reads it before the probe starts, so it's written in place: an atomic
    /// write, a new file renamed over it, was refused at times on GitHub's
    /// Windows runner (*You don't have permission*).
    public static func write(_ roots: WindowsRoots, run: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("windows-roots-\(run).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(roots).write(to: url)
        return url
    }

    /// The path with every symlink and junction on it followed, as
    /// `GetFinalPathNameByHandleW` gives it (`\\?\C:\…`), or as it is when
    /// it can't be opened (it doesn't exist).
    public static func finalPath(_ path: String) -> String {
        // No access asked, so a file another process holds still opens; folders need backup semantics.
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let handle, handle != HANDLE(bitPattern: -1) else { return path }
        defer { CloseHandle(handle) }
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), DWORD(FILE_NAME_NORMALIZED))
        guard length > 0, Int(length) < buffer.count else { return path }
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }
}
