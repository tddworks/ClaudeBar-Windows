import Foundation
import Leaderboard

/// ClaudeBar for Windows' composition root: ClaudeBar's factories, this
/// client's settings file and token logs, and the version it names itself by.
@MainActor
public final class Client {
    /// How this client names itself on every request (`X-Client`).
    nonisolated public static let version = "0.1.0"
    nonisolated public static var xClient: String { "claudebar-windows/\(version)" }

    public let api: any LeaderboardAPI
    public let keys: any SigningKeyStore
    public let settings: any LeaderboardSettingsRepository
    public let logs: ProviderTokenLogs
    public let machine: any MachineIdentity

    public init(api: (any LeaderboardAPI)? = nil, keys: (any SigningKeyStore)? = nil,
                settings: (any LeaderboardSettingsRepository)? = nil, logs: ProviderTokenLogs? = nil,
                machine: (any MachineIdentity)? = nil) {
        self.api = api ?? Leaderboard.makeAPI(client: Self.xClient)
        self.keys = keys ?? Leaderboard.makeKeyStore()
        self.settings = settings ?? SettingsFile()
        self.logs = logs ?? ProviderTokenLogs()
        self.machine = machine ?? Leaderboard.makeMachineIdentity()
    }

    /// The membership as the settings file and Credential Manager hold it now.
    /// The app and the hourly uploader are separate processes, so each action
    /// starts from a fresh read rather than a copy one of them made earlier.
    public func membership() -> LeaderboardMembership {
        LeaderboardMembership(api: api, keys: keys, settings: settings, logs: logs, machine: machine)
    }

    public func uploader(for membership: LeaderboardMembership) -> LeaderboardUploader {
        LeaderboardUploader(membership: membership, logs: logs, api: api)
    }
}
