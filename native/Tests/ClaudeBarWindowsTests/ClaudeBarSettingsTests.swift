import Foundation
import Providers
import Quotas
import Testing
@testable import ClaudeBarWindows

/// The HUD's providers follow the person's settings where ClaudeBar keeps
/// them, `~/.claudebar/settings.json`, read as ClaudeBar reads it.
@Suite
struct ClaudeBarSettingsTests {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cbw-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("settings.json")

    private func keep(_ json: String) throws -> ClaudeBarSettings {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return ClaudeBarSettings(url: url)
    }

    @Test func `should read the person's settings where ClaudeBar keeps them`() throws {
        let settings = try keep(#"""
        {"app": {"burnRateWarningEnabled": true},
         "providers": {"order": ["codex", "claude"],
                       "gemini": {"isEnabled": false},
                       "claude": {"hiddenQuotaKeys": ["weekly"], "cliPath": "C:\\tools\\claude.exe",
                                  "defaultAccountLabel": "Home", "accountOrder": ["work", "default"],
                                  "accounts": [{"accountId": "work", "label": "Work", "probeConfig": {"folder": "C:\\work"}}]}},
         "claude": {"probeMode": "api", "cliFallbackEnabled": false},
         "kimi": {"region": "cn"}}
        """#)

        #expect(settings.statusPolicy() == .paceAware)
        #expect(settings.providerOrder() == ["codex", "claude"])
        #expect(!settings.isEnabled(forProvider: "gemini", defaultValue: true))
        #expect(settings.isEnabled(forProvider: "claude", defaultValue: true))
        #expect(settings.hiddenQuotaKeys(forProvider: "claude") == ["weekly"])
        #expect(settings.cliPath(forProvider: "claude") == #"C:\tools\claude.exe"#)
        #expect(settings.defaultAccountLabel(forProvider: "claude") == "Home")
        #expect(settings.accountOrder(forProvider: "claude") == ["work", "default"])
        #expect(settings.accounts(forProvider: "claude") == [ProviderAccountConfig(accountId: "work", label: "Work", probeConfig: ["folder": #"C:\work"#])])
        #expect(settings.dataSourceKind(forProvider: "claude") == "api")
        #expect(settings.isOn("cliFallbackEnabled", forProvider: "claude") == false)
        #expect(settings.value("region", forProvider: "kimi") == "cn")
    }

    @Test func `should keep every default when ClaudeBar keeps no settings on this PC`() {
        let settings = ClaudeBarSettings(url: url)

        #expect(settings.statusPolicy() == .absolute)
        #expect(settings.isEnabled(forProvider: "gemini", defaultValue: true))
        #expect(!settings.isEnabled(forProvider: "gemini", defaultValue: false))
        #expect(settings.accounts(forProvider: "claude").isEmpty)
        #expect(settings.providerOrder().isEmpty)
        #expect(settings.hiddenQuotaKeys(forProvider: "claude").isEmpty)
        #expect(settings.isOn("cliFallbackEnabled", forProvider: "claude") == nil)
    }
}
