import Foundation
import Testing
@testable import ClaudeBarShared

/// Whether a WSL source and a Windows one are the same place
/// (docs/plans/2026-11-03-wsl-design.md, Folders shared with Windows; Tests,
/// Matching): both in Windows form, in the forms the two sides produce.
@Suite
struct SharedRootsTests {
    private let windows = ProviderRoots(provider: "claude", credentials: [#"C:\Users\me\.claude"#, #"C:\Users\me\.claude.json"#],
                                        logs: [#"C:\Users\me\.claude\projects"#])

    @Test func `should call a WSL folder linked to the one Windows reads shared`() {
        #expect(SharedRoots.isShared(#"C:\Users\me\.claude"#, #"C:\Users\me\.claude"#))
    }

    @Test func `should keep a folder on a drive but elsewhere`() {
        #expect(!SharedRoots.isShared(#"D:\wsl-data\.claude"#, #"C:\Users\me\.claude"#))
    }

    @Test func `should match by whole names, an ancestor either way`() {
        #expect(SharedRoots.isShared(#"C:\Users\me\.claude\.credentials.json"#, #"C:\Users\me\.claude"#))
        #expect(SharedRoots.isShared(#"C:\Users\me"#, #"C:\Users\me\.claude"#))
        #expect(!SharedRoots.isShared(#"C:\Users\me\.claude-work"#, #"C:\Users\me\.claude"#))
    }

    @Test func `should ignore case, the separator and a trailing one`() {
        #expect(SharedRoots.isShared("c:/users/ME/.Claude/", #"C:\Users\me\.claude"#))
    }

    @Test func `should read the forms GetFinalPathNameByHandleW returns`() {
        #expect(SharedRoots.isShared(#"\\?\C:\Users\me\.claude"#, #"C:\Users\me\.claude"#))
        #expect(SharedRoots.isShared(#"\\?\UNC\wsl.localhost\Ubuntu-26.04\home\me\.claude"#, #"\\wsl.localhost\Ubuntu-26.04\home\me\.claude"#))
    }

    @Test func `should read wsl$ as wsl.localhost`() {
        #expect(SharedRoots.isShared(#"\\wsl$\Ubuntu-26.04\home\me\.claude"#, #"\\wsl.localhost\Ubuntu-26.04\home\me\.claude"#))
    }

    @Test func `should skip a shared credential root and keep a distinct log root`() {
        let skips = SharedRoots.skips(provider: "claude", roots: [
            .init(kind: .credentials, windowsPath: #"C:\Users\me\.claude"#),
            .init(kind: .logs, windowsPath: #"\\wsl.localhost\Ubuntu-26.04\home\me\work\projects"#),
        ], windows: windows)
        #expect(skips == [.init(provider: "claude", kind: .credentials, windowsPath: #"C:\Users\me\.claude"#, reason: .shared)])
    }

    @Test func `should skip only the provider whose root is shared`() {
        let codex = ProviderRoots(provider: "codex", credentials: [#"C:\Users\me\.codex"#], logs: [#"C:\Users\me\.codex\sessions"#])
        #expect(SharedRoots.skips(provider: "codex", roots: [.init(kind: .logs, windowsPath: #"C:\Users\me\.codex\sessions"#)], windows: codex).count == 1)
        #expect(SharedRoots.skips(provider: "claude", roots: [.init(kind: .logs, windowsPath: #"\\wsl.localhost\U\home\me\.claude\projects"#)], windows: windows).isEmpty)
    }

    @Test func `should fail closed on a root it couldn't map to Windows`() {
        #expect(SharedRoots.skips(provider: "claude", roots: [.init(kind: .logs, windowsPath: nil)], windows: windows)
                == [.init(provider: "claude", kind: .logs, windowsPath: nil, reason: .uncheckable)])
    }
}
