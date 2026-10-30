import Foundation
import Leaderboard
import Providers
import Quotas

/// This PC's token logs: every built-in provider whose definition reads usage
/// history (Claude, Codex, Mistral, omp), at its default login, read through
/// ClaudeBar's `Providers` exactly as the Mac reads them.
@MainActor
public final class ProviderTokenLogs: TokenLogs {
    /// A provider as the app shows it: its name, and its colour in a light
    /// and a dark theme (`#RRGGBB`), from its definition's look, as on the Mac.
    public struct Provider: Sendable, Equatable {
        public let id: String
        public let name: String
        public let light: String
        public let dark: String
    }

    private struct Login {
        let provider: Provider
        let history: UsageHistory
    }

    private let logins: [Login]

    public init(settings: any MultiAccountSettingsRepository = DefaultProviderSettings()) {
        logins = ProviderFactory.builtInDefinitions.values
            .filter { $0.usageHistory != nil }
            .sorted { $0.id < $1.id }
            .compactMap { definition in
                ProviderFactory.make(definition, settings: settings).usageHistory.map {
                    let color = definition.profile.look.color
                    return Login(provider: Provider(id: definition.id, name: definition.profile.name,
                                                    light: Self.hex(color?.light), dark: Self.hex(color?.dark)),
                                 history: $0)
                }
            }
    }

    public var providersWithLogs: Set<String> { Set(logins.map(\.provider.id)) }

    /// The providers, in a stable order, with the names people know them by.
    public var providers: [Provider] { logins.map(\.provider) }

    /// A definition's colour as `#RRGGBB`; grey for one without a colour.
    static func hex(_ rgb: ProviderLook.RGB?) -> String {
        guard let rgb else { return "#8A8A8A" }
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return "#" + [rgb.red, rgb.green, rgb.blue].map { String(byte($0), radix: 16).uppercased() }
            .map { $0.count == 1 ? "0" + $0 : $0 }.joined()
    }

    public func days(in range: DateRange) async -> [LoginDays] {
        var result: [LoginDays] = []
        for login in logins {
            result.append(LoginDays(providerId: login.provider.id, days: await login.history.days(in: range).stats))
        }
        return result
    }
}

extension LoginDays {
    /// The days from `range`'s first through its last: a shorter run taken
    /// from a longer read, instead of reading every log again.
    public func within(_ range: DateRange) -> LoginDays {
        LoginDays(providerId: providerId, days: days.filter { $0.date >= range.first && $0.date <= range.last })
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
