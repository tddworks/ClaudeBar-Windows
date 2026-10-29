import Foundation
import Providers
import Quotas

/// The person's provider settings as ClaudeBar keeps them: its own
/// `~/.claudebar/settings.json` (here `%USERPROFILE%\.claudebar\settings.json`),
/// each dotted key a path into the JSON, as ClaudeBar's `JSONSettingsStore`
/// reads it. Which providers are on, the logins they hold and in what order,
/// the quotas hidden, a CLI's location, the data source picked, and how
/// strict to be. A missing file holds nothing, so every default applies.
///
/// Read only, and read afresh each time, so a change ClaudeBar makes applies
/// at once. The HUD changes no setting: every save here keeps nothing.
public final class ClaudeBarSettings: MultiAccountSettingsRepository, @unchecked Sendable {
    public let url: URL

    public init(url: URL = ClaudeBarSettings.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/settings.json")
    }

    /// HOW STRICT TO BE: pace-aware when the person turned on *warn when a
    /// quota will run out before it resets*, as on the Mac.
    public func statusPolicy() -> StatusPolicy {
        .from(burnRateWarningEnabled: read("app.burnRateWarningEnabled") ?? false)
    }

    // MARK: - What ClaudeBar keeps

    public func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool {
        read("providers.\(id).isEnabled") ?? defaultValue
    }

    public func customCardURL(forProvider id: String) -> String? { read("providers.\(id).customCardURL") }
    public func dataSourceKind(forProvider id: String) -> String? { read("\(id).probeMode") }
    public func isOn(_ setting: String, forProvider id: String) -> Bool? { read("\(id).\(setting)") }
    public func providerOrder() -> [String] { read("providers.order") ?? [] }
    public func cliPath(forProvider id: String) -> String? { read("providers.\(id).cliPath") }

    /// A value as text; a list reads as `a, b`, as ClaudeBar reads it.
    public func value(_ setting: String, forProvider id: String) -> String? {
        let key = "\(id).\(setting)"
        if let text: String = read(key) { return text }
        let list: [String]? = read(key)
        return list?.joined(separator: ", ")
    }

    public func hiddenQuotaKeys(forProvider id: String) -> Set<String> {
        Set(read("providers.\(id).hiddenQuotaKeys") ?? [String]())
    }

    public func accounts(forProvider id: String) -> [ProviderAccountConfig] {
        let raw: [Any] = read("providers.\(id).accounts") ?? []
        return raw.compactMap { entry in
            guard JSONSerialization.isValidJSONObject(entry),
                  let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? JSONDecoder().decode(ProviderAccountConfig.self, from: data)
        }
    }

    public func defaultAccountLabel(forProvider id: String) -> String? { read("providers.\(id).defaultAccountLabel") }
    public func accountOrder(forProvider id: String) -> [String] { read("providers.\(id).accountOrder") ?? [] }

    // MARK: - Saves keep nothing

    public func setEnabled(_ enabled: Bool, forProvider id: String) {}
    public func setCustomCardURL(_ url: String?, forProvider id: String) {}
    public func setDataSourceKind(_ kind: String, forProvider id: String) {}
    public func setOn(_ on: Bool, _ setting: String, forProvider id: String) {}
    public func setProviderOrder(_ order: [String]) {}
    public func setValue(_ value: String?, _ setting: String, forProvider id: String) {}
    public func setCLIPath(_ path: String?, forProvider id: String) {}
    public func setHiddenQuotaKeys(_ keys: Set<String>, forProvider id: String) {}
    public func addAccount(_ config: ProviderAccountConfig, forProvider id: String) {}
    public func removeAccount(accountId: String, forProvider id: String) {}
    public func updateAccount(_ config: ProviderAccountConfig, forProvider id: String) {}
    public func setDefaultAccountLabel(_ label: String?, forProvider id: String) {}
    public func setAccountOrder(_ accountIds: [String], forProvider id: String) {}

    // MARK: - The file

    /// The value at a dotted key, when it is there and of type `T`.
    private func read<T>(_ key: String) -> T? {
        guard let data = try? Data(contentsOf: url),
              var node = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for part in key.split(separator: ".") {
            guard let object = node as? [String: Any], let next = object[String(part)] else { return nil }
            node = next
        }
        return node as? T
    }
}
