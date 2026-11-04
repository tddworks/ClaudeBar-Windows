import ClaudeBarShared
import Foundation
import Providers
import Testing
@testable import ClaudeBarWindows

/// This PC's roots for a probe run (design, *Folders shared with Windows*):
/// expanded as ClaudeBar expands them, then followed through junctions.
@Suite
struct WslWindowsRootsTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cbw-roots-\(UUID().uuidString)", isDirectory: true)
    private var home: URL { folder.appendingPathComponent("home", isDirectory: true) }
    private let claude = ProviderFactory.builtInDefinitions["claude"]!

    private func make(_ environment: @escaping @Sendable (String) -> String? = { _ in nil }) -> ProviderRoots {
        WslWindowsRoots.make(distro: "Ubuntu-26.04", definitions: [claude], homeDirectory: home, environment: environment).providers[0]
    }

    private func windowsPath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    }

    @Test func `should follow a junction to the folder it points at`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let link = Process()
        link.executableURL = URL(fileURLWithPath: #"C:\Windows\System32\cmd.exe"#)
        link.arguments = ["/c", "mklink", "/J", windowsPath(home.appendingPathComponent(".claude")), windowsPath(target)]
        link.standardOutput = FileHandle.nullDevice
        try link.run()
        link.waitUntilExit()
        try #require(link.terminationStatus == 0)

        let roots = make()

        // Claude's account folder comes first; the files in it don't exist, and stay as expanded.
        let account = try #require(roots.credentials.first)
        #expect(account.hasPrefix(#"\\?\"#))
        #expect(account == WslWindowsRoots.finalPath(windowsPath(target)))
        #expect(SharedRoots.isSame(account, windowsPath(target)))
    }

    @Test func `should keep a root that doesn't exist as expanded`() {
        let roots = make()

        #expect(roots == ProviderRoots.of(claude, homeDirectory: home, environment: { _ in nil }))
        #expect(!roots.credentials.isEmpty && !roots.logs.isEmpty)
    }

    @Test func `should move Claude's roots where CLAUDE_CONFIG_DIR points`() {
        let elsewhere = windowsPath(folder.appendingPathComponent("config", isDirectory: true))

        let roots = make { $0 == "CLAUDE_CONFIG_DIR" ? elsewhere : nil }

        // The account folder and the records move; `~/.claude.json`, which Claude reads either way, stays.
        #expect(roots.credentials.first.map { SharedRoots.isSame($0, elsewhere) } == true)
        #expect(roots.logs.contains { SharedRoots.overlaps($0, elsewhere) })
        #expect(make().credentials.first.map { SharedRoots.isSame($0, elsewhere) } == false)
    }

    @Test func `should write the run's own file, which reads back`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let roots = WslWindowsRoots.make(distro: "Ubuntu-26.04", definitions: [claude], homeDirectory: home, environment: { _ in nil })

        let url = try WslWindowsRoots.write(roots, run: "0123456789abcdef0123456789abcdef", in: folder)

        #expect(url.lastPathComponent == "windows-roots-0123456789abcdef0123456789abcdef.json")
        #expect(try JSONDecoder().decode(WindowsRoots.self, from: Data(contentsOf: url)) == roots)
        #expect(roots.version == ClientVersion.version && roots.distro == "Ubuntu-26.04")
    }
}
