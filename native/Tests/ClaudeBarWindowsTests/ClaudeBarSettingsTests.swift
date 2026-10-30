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

    @Test func `should read a number as text, as ClaudeBar reads a value an old card saved as one`() throws {
        let settings = try keep(#"""
        {"zai": {"limit": 5, "ratio": 2.5, "strict": true, "regions": ["cn", "us"]}}
        """#)

        #expect(settings.value("limit", forProvider: "zai") == "5")
        #expect(settings.value("ratio", forProvider: "zai") == "2.5")
        #expect(settings.value("regions", forProvider: "zai") == "cn, us")
        #expect(settings.value("strict", forProvider: "zai") == nil, "a switch isn't text, in ClaudeBar's store either")
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
