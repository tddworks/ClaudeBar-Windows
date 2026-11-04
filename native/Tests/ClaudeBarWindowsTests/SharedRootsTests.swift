import Foundation
import Testing
@testable import ClaudeBarShared

/// Whether a WSL source and a Windows one are the same place
/// (docs/plans/2026-11-03-wsl-design.md, Folders shared with Windows; Tests,
/// Matching): both in Windows form, in the forms the two sides produce. A
/// credential root is shared only when it's the same place as one Windows
/// reads; a log root when it overlaps one of Windows' log roots.
@Suite
struct SharedRootsTests {
    private let windows = ProviderRoots(provider: "claude", credentials: [#"C:\Users\me\.claude"#, #"C:\Users\me\.claude.json"#],
                                        logs: [#"C:\Users\me\.claude\projects"#])

    @Test func `should call a WSL folder linked to the one Windows reads the same place`() {
        #expect(SharedRoots.isSame(#"C:\Users\me\.claude"#, #"C:\Users\me\.claude"#))
    }

    @Test func `should keep a folder on a drive but elsewhere`() {
        #expect(!SharedRoots.isSame(#"D:\wsl-data\.claude"#, #"C:\Users\me\.claude"#))
        #expect(!SharedRoots.overlaps(#"D:\wsl-data\.claude"#, #"C:\Users\me\.claude"#))
    }

    @Test func `should overlap by whole names, an ancestor either way, and be the same place only when equal`() {
        #expect(SharedRoots.overlaps(#"C:\Users\me\.claude\projects\foo"#, #"C:\Users\me\.claude\projects"#))
        #expect(SharedRoots.overlaps(#"C:\Users\me"#, #"C:\Users\me\.claude"#))
        #expect(!SharedRoots.overlaps(#"C:\Users\me\.claude-work"#, #"C:\Users\me\.claude"#))
        #expect(!SharedRoots.isSame(#"C:\Users\me\.claude\.credentials.json"#, #"C:\Users\me\.claude"#))
    }

    @Test func `should ignore case, the separator and a trailing one`() {
        #expect(SharedRoots.isSame("c:/users/ME/.Claude/", #"C:\Users\me\.claude"#))
    }

    @Test func `should read the forms GetFinalPathNameByHandleW returns`() {
        #expect(SharedRoots.isSame(#"\\?\C:\Users\me\.claude"#, #"C:\Users\me\.claude"#))
        #expect(SharedRoots.isSame(#"\\?\UNC\wsl.localhost\Ubuntu-26.04\home\me\.claude"#, #"\\wsl.localhost\Ubuntu-26.04\home\me\.claude"#))
    }

    @Test func `should read wsl$ as wsl.localhost`() {
        #expect(SharedRoots.isSame(#"\\wsl$\Ubuntu-26.04\home\me\.claude"#, #"\\wsl.localhost\Ubuntu-26.04\home\me\.claude"#))
    }

    @Test func `should keep a WSL account nested in the folder Windows reads, distinct from it`() {
        let windows = ProviderRoots(provider: "claude", credentials: [#"C:\Users\you\.claude"#, #"C:\Users\you\.claude\.credentials.json"#],
                                    logs: [#"C:\Users\you\.claude\projects"#])
        let skips = SharedRoots.skips(provider: "claude", roots: [
            .init(kind: .credentials, windowsPath: #"C:\Users\you\.claude\wsl"#),
            .init(kind: .credentials, windowsPath: #"C:\Users\you\.claude\wsl\.credentials.json"#),
            .init(kind: .logs, windowsPath: #"C:\Users\you\.claude\wsl\projects"#),
        ], windows: windows)
        #expect(skips.isEmpty)
    }

    @Test func `should skip every root of a folder linked whole to the one Windows reads`() {
        let windows = ProviderRoots(provider: "claude", credentials: [#"C:\Users\you\.claude"#, #"C:\Users\you\.claude\.credentials.json"#],
                                    logs: [#"C:\Users\you\.claude\projects"#])
        let skips = SharedRoots.skips(provider: "claude", roots: [
            .init(kind: .credentials, windowsPath: #"C:\Users\you\.claude"#),
            .init(kind: .credentials, windowsPath: #"C:\Users\you\.claude\.credentials.json"#),
            .init(kind: .logs, windowsPath: #"C:\Users\you\.claude\projects"#),
        ], windows: windows)
        #expect(skips == [
            .init(provider: "claude", kind: .credentials, windowsPath: #"C:\Users\you\.claude"#, reason: .shared),
            .init(provider: "claude", kind: .credentials, windowsPath: #"C:\Users\you\.claude\.credentials.json"#, reason: .shared),
            .init(provider: "claude", kind: .logs, windowsPath: #"C:\Users\you\.claude\projects"#, reason: .shared),
        ])
    }

    @Test func `should skip a log root under one of Windows' log roots`() {
        let skips = SharedRoots.skips(provider: "claude", roots: [.init(kind: .logs, windowsPath: #"C:\Users\me\.claude\projects\foo"#)],
                                      windows: windows)
        #expect(skips == [.init(provider: "claude", kind: .logs, windowsPath: #"C:\Users\me\.claude\projects"#, reason: .shared)])
    }

    @Test func `should keep a log root that is only one of Windows' credential folders`() {
        let windows = ProviderRoots(provider: "claude", credentials: [#"C:\Users\me\.claude"#], logs: [])
        #expect(SharedRoots.skips(provider: "claude", roots: [.init(kind: .logs, windowsPath: #"C:\Users\me\.claude"#)], windows: windows).isEmpty)
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
