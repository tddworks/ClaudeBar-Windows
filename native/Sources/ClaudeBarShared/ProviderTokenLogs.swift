import DataSources
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

    /// `except`: providers left out, in WSL those whose usage records Windows
    /// reads too, so their days aren't counted twice
    /// (docs/plans/2026-11-03-wsl-design.md, Folders shared with Windows).
    ///
    /// `home`: the folder read as the person's home. Without one, the logs are
    /// the person's, read exactly as the Mac reads them, with the closed days
    /// and what each scan read kept in their `~\.claudebar\usage-history`.
    /// With one, as a test gives a folder of its own: the logs under it, with
    /// no environment variable to point elsewhere, and what reading them keeps
    /// in its `.claudebar\usage-history`, so nothing of the person's is read
    /// or written.
    public init(settings: any MultiAccountSettingsRepository = DefaultProviderSettings(), except: Set<String> = [],
                home: URL? = nil) {
        logins = ProviderFactory.builtInDefinitions.values
            .filter { $0.usageHistory != nil && !except.contains($0.id) }
            .sorted { $0.id < $1.id }
            .compactMap { definition in
                let history = if let home { Self.history(definition, home: home) }
                              else { ProviderFactory.make(definition, settings: settings).usageHistory }
                return history.map {
                    let color = definition.profile.look.color
                    return Login(provider: Provider(id: definition.id, name: definition.profile.name,
                                                    light: Self.hex(color?.light), dark: Self.hex(color?.dark)),
                                 history: $0)
                }
            }
    }

    /// A definition's default login read under `home`, as `ProviderFactory`
    /// reads it under the person's.
    private static func history(_ definition: ProviderDefinition, home: URL) -> UsageHistory? {
        let kept = home.appendingPathComponent(".claudebar", isDirectory: true)
            .appendingPathComponent("usage-history", isDirectory: true)
        let scans = kept.appendingPathComponent("scans", isDirectory: true)
        let environment: @Sendable (String) -> String? = { _ in nil }
        return definition.usageHistory(forDefaultAccount: definition.defaultAccountValues).map {
            UsageHistory($0, login: definition.id,
                         log: { DataSources.makeUsageLog($0, scripts: ProviderFactory.builtInScripts, environment: environment,
                                                         homeDirectory: home, scans: scans) },
                         ledger: { DayLedger(store: FolderLedgerStore(directory: kept), key: $0) })
        }
    }

    public var providersWithLogs: Set<String> { Set(logins.map(\.provider.id)) }

    /// The providers, in a stable order, with the names people know them by.
    public var providers: [Provider] { logins.map(\.provider) }

    /// A definition's colour as `#RRGGBB`; grey for one without a colour.
    nonisolated static func hex(_ rgb: ProviderLook.RGB?) -> String {
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

/// Kept days in a folder, a file a login, named and written as ClaudeBar's own
/// store writes them in `~/.claudebar/usage-history`: for a home a test gives,
/// which that store can't be pointed at.
private struct FolderLedgerStore: LedgerStore {
    let directory: URL

    func load(_ key: String) -> LedgerPage? {
        FileManager.default.contents(atPath: file(key).path).flatMap { try? JSONDecoder().decode(LedgerPage.self, from: $0) }
    }

    func save(_ page: LedgerPage, for key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(page) else { return }
        try? AtomicFile.write(data, to: file(key))
    }

    private func file(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
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
