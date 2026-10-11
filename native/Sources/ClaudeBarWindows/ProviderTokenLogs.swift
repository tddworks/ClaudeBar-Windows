import Foundation
import Leaderboard
import Providers
import Quotas

/// This PC's token logs: every built-in provider whose definition reads usage
/// history (Claude, Codex, Mistral, omp), at its default login, read through
/// ClaudeBar's `Providers` exactly as the Mac reads them.
@MainActor
public final class ProviderTokenLogs: TokenLogs {
    private struct Login {
        let providerId: String
        let name: String
        let history: UsageHistory
    }

    private let logins: [Login]

    public init(settings: any MultiAccountSettingsRepository = DefaultProviderSettings()) {
        logins = ProviderFactory.builtInDefinitions.values
            .filter { $0.usageHistory != nil }
            .sorted { $0.id < $1.id }
            .compactMap { definition in
                ProviderFactory.make(definition, settings: settings).usageHistory.map {
                    Login(providerId: definition.id, name: definition.profile.name, history: $0)
                }
            }
    }

    public var providersWithLogs: Set<String> { Set(logins.map(\.providerId)) }

    /// The providers, in a stable order, with the names people know them by.
    public var providers: [(id: String, name: String)] { logins.map { ($0.providerId, $0.name) } }

    public func days(in range: DateRange) async -> [LoginDays] {
        var result: [LoginDays] = []
        for login in logins {
            result.append(LoginDays(providerId: login.providerId, days: await login.history.days(in: range).stats))
        }
        return result
    }
}

/// Provider settings for a client that only reads token logs: every provider
/// on, one login each, nothing kept.
public final class DefaultProviderSettings: MultiAccountSettingsRepository, @unchecked Sendable {
    public init() {}

    public func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool { defaultValue }
    public func setEnabled(_ enabled: Bool, forProvider id: String) {}
    public func customCardURL(forProvider id: String) -> String? { nil }
    public func setCustomCardURL(_ url: String?, forProvider id: String) {}
    public func accounts(forProvider id: String) -> [ProviderAccountConfig] { [] }
    public func addAccount(_ config: ProviderAccountConfig, forProvider id: String) {}
    public func removeAccount(accountId: String, forProvider id: String) {}
    public func updateAccount(_ config: ProviderAccountConfig, forProvider id: String) {}
    public func defaultAccountLabel(forProvider id: String) -> String? { nil }
    public func setDefaultAccountLabel(_ label: String?, forProvider id: String) {}
    public func accountOrder(forProvider id: String) -> [String] { [] }
    public func setAccountOrder(_ accountIds: [String], forProvider id: String) {}
}
