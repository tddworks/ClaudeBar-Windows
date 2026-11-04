import DataSources
import Foundation
import Providers
import Testing
@testable import ClaudeBarShared

/// The places a provider's default login is read from, on one side
/// (docs/plans/2026-11-03-wsl-design.md, Folders shared with Windows), from
/// the built-in definitions at the pin. Each test names every root, so a
/// change in how ClaudeBar encodes a definition fails here.
@Suite
struct ProviderRootsTests {
    private let home = URL(fileURLWithPath: "/home/me")

    private func roots(_ id: String, _ environment: [String: String] = [:]) -> ProviderRoots {
        ProviderRoots.of(ProviderFactory.builtInDefinitions[id]!, homeDirectory: home, environment: { environment[$0] })
    }

    /// A path under the home, as this platform's `expandPath` writes it.
    private func home(_ rest: String) -> String { home.path + rest }

    @Test func `should give Claude's account folder and its files as credential roots, and its records as log roots`() {
        let claude = roots("claude")
        #expect(claude.credentials == [home("/.claude"), home("/.claude/.claude.json"), home("/.claude.json"),
                                       home("/.claude/.credentials.json")])
        // The desktop app's records too, where this platform keeps app data.
        let desktop = DataSources.expandPath("{{platform.appData}}/Claude/buddy-tokens.json", homeDirectory: home, environment: { _ in nil })
        #expect(Set(claude.logs) == [home("/.claude/projects"), desktop])
    }

    @Test func `should follow CODEX_HOME as ClaudeBar does`() {
        let codex = roots("codex", ["CODEX_HOME": "/home/me/alt-codex"])
        #expect(codex.credentials == ["/home/me/alt-codex", "/home/me/alt-codex/auth.json"])
        #expect(codex.logs == ["/home/me/alt-codex/sessions"])
        #expect(roots("codex").credentials == [home("/.codex"), home("/.codex/auth.json")])
    }

    @Test func `should take a log glob's folder before its first wildcard`() {
        #expect(roots("omp").logs == [home("/.omp/agent/sessions")])
        #expect(roots("omp").credentials == [])
    }

    @Test func `should take a database file whole`() {
        let opencode = roots("opencode-go")
        #expect(opencode.credentials == [home("/.local/share/opencode/auth.json"), home("/.local/share/opencode/opencode.db")])
        #expect(opencode.logs == [home("/.local/share/opencode/opencode.db")])
    }

    @Test func `should take a folder an account setting names, not only the account's folder`() {
        #expect(roots("kimi").credentials == [home("/.kimi")])
        #expect(roots("kimi", ["KIMI_SHARE_DIR": "/home/me/k"]).credentials == ["/home/me/k"])
    }
}
