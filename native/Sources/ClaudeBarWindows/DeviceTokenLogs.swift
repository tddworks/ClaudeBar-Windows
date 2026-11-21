import ClaudeBarShared
import DataSources
import Foundation
import Leaderboard
import Quotas

/// The Leaderboard's token logs on this PC (docs/plans/2026-11-03-wsl-design.md,
/// The Leaderboard (phase 2)): this PC's logins, and each WSL distro's kept
/// days as plain `LoginDays`, which ClaudeBar's `DailyTokens.summed` adds to
/// this PC's day of the same label, behind the `sharing` filter.
@MainActor
public final class DeviceTokenLogs: TokenLogs {
    /// This PC's providers, as `cbw_state` lists them.
    public let providers: [ProviderTokenLogs.Provider]
    private let windows: any TokenLogs
    private let wsl: WslDays
    private let calendar: () -> Calendar

    public convenience init(windows: ProviderTokenLogs = ProviderTokenLogs(), wsl: WslDays = WslDays(),
                            calendar: @escaping () -> Calendar = DataSources.calendar) {
        self.init(windows: windows, providers: windows.providers, wsl: wsl, calendar: calendar)
    }

    init(windows: any TokenLogs, providers: [ProviderTokenLogs.Provider], wsl: WslDays, calendar: @escaping () -> Calendar) {
        self.windows = windows
        self.providers = providers
        self.wsl = wsl
        self.calendar = calendar
    }

    /// This PC's and the distros' kept days'.
    public var providersWithLogs: Set<String> { windows.providersWithLogs.union(wsl.providers) }

    /// The distros' days first, then this PC's.
    public func days(in range: DateRange) async -> [LoginDays] {
        let distros = await wsl.days(in: range, calendar: calendar())
        return distros + (await windows.days(in: range))
    }
}
