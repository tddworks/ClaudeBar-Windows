import Foundation
import Testing
@testable import ClaudeBarShared

/// The probe leaves a provider whose log root Windows reads too out of its
/// token logs (docs/plans/2026-11-03-wsl-design.md, Folders shared with
/// Windows), so its days aren't counted twice.
@Suite
struct ProviderTokenLogsTests {
    @Test @MainActor func `should leave a provider in except out of the token logs`() {
        #expect(!ProviderTokenLogs(except: ["claude"]).providersWithLogs.contains("claude"))
        #expect(ProviderTokenLogs(except: ["claude"]).providersWithLogs.contains("codex"))
    }
}
