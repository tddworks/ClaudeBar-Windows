import ClaudeBarShared
import DataSources
import Foundation
import Leaderboard
import Quotas

/// Each distro's last days, kept for the Leaderboard while it can't be read
/// (docs/plans/2026-11-03-wsl-design.md, No day shrinks):
/// `%LOCALAPPDATA%\ClaudeBar\wsl\days\<distro>.json`, one `Entry` each,
/// written by every probe run whose days were counted in the zone it was
/// sent, under the distro's mutex. The app's uploads, its preview and the
/// hourly uploader read them; nothing deletes them, and a day leaves them
/// with the upload window.
public struct WslKeptDays: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let distro: String
        /// The zone the days were counted in: the one the app sent.
        public let timeZone: String
        /// When the run that wrote this answered.
        public let answeredAt: Date
        /// When each provider's days and roots were read: `answeredAt`, or the
        /// earlier entry's time for a provider carried over (`entry(...)`).
        public let readAt: [String: Date]
        public let logRoots: [ProbeReading.LogRoot]
        public let days: [DailyTokens]

        public init(distro: String, timeZone: String, answeredAt: Date, readAt: [String: Date],
                    logRoots: [ProbeReading.LogRoot], days: [DailyTokens]) {
            self.distro = distro
            self.timeZone = timeZone
            self.answeredAt = answeredAt
            self.readAt = readAt
            self.logRoots = logRoots
            self.days = days
        }

        /// When `provider`'s days were read.
        func time(of provider: String) -> Date { readAt[provider] ?? answeredAt }

        /// The same entry without `provider`'s days, and without its log
        /// roots and read time too when `roots` is false.
        func dropping(_ provider: String, roots: Bool) -> Entry {
            Entry(distro: distro, timeZone: timeZone, answeredAt: answeredAt,
                  readAt: roots ? readAt.filter { $0.key != provider } : readAt,
                  logRoots: roots ? logRoots.filter { $0.provider != provider } : logRoots,
                  days: days.filter { $0.provider != provider })
        }
    }

    /// A log root of a distro's that another's kept entry reads too.
    public struct SharedLog: Codable, Equatable, Sendable {
        public let provider: String
        public let windowsPath: String
        /// The other distros of its group, by name (Swift's `<`).
        public let with: [String]

        public init(provider: String, windowsPath: String, with: [String]) {
            self.provider = provider
            self.windowsPath = windowsPath
            self.with = with
        }
    }

    /// What `current` leaves: the entries as they count, each line for the
    /// log, and each distro's shared log roots.
    public struct Counted: Equatable, Sendable {
        public let entries: [Entry]
        public let leftOut: [String]
        public let shared: [String: [SharedLog]]
    }

    /// `%LOCALAPPDATA%\ClaudeBar\wsl\days`.
    public static var folder: URL { WslProbe.folder.appendingPathComponent("days", isDirectory: true) }

    private let folder: URL

    public init(folder: URL = WslKeptDays.folder) {
        self.folder = folder
    }

    /// Replaces the distro's file: written to a new file in the folder, then
    /// moved over it (`AtomicFile`), so a reader finds the old entry or the
    /// new, never part of either. Creates the folder.
    public func save(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AtomicFile.write(ProbeReading.encoder().encode(entry), to: file(entry.distro))
    }

    /// Every `*.json` in the folder that decodes, sorted by `distro` (Swift's
    /// `<`); one that doesn't decode is left out.
    public func all() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "json" }.compactMap(Self.read).sorted { $0.distro < $1.distro }
    }

    /// The distro's file, nil when there's none or it doesn't decode.
    public func entry(for distro: String) -> Entry? {
        Self.read(file(distro))
    }

    private func file(_ distro: String) -> URL {
        folder.appendingPathComponent(distro + ".json")
    }

    private static func read(_ url: URL) -> Entry? {
        FileManager.default.contents(atPath: url.path).flatMap { try? ProbeReading.decoder().decode(Entry.self, from: $0) }
    }

    /// What a run keeps (design, No day shrinks; A root a run couldn't check
    /// keeps the days from before): the reading's `days` and `logRoots`, read
    /// at `answeredAt`. A provider whose log root the run couldn't check (a
    /// `logs` skip, `uncheckable`), of which the probe reads no days, takes
    /// its days, log roots and read time from `earlier` instead, when that
    /// was counted in the same zone and has them. Nothing else is carried.
    public static func entry(distro: String, reading: ProbeReading, days: [DailyTokens], answeredAt: Date,
                             earlier: Entry?) -> Entry {
        var keptDays = days
        var roots = reading.logRoots
        var readAt: [String: Date] = [:]
        for provider in keptDays.map(\.provider) + roots.map(\.provider) { readAt[provider] = answeredAt }
        if let earlier, earlier.timeZone == reading.timeZone {
            let unchecked = reading.skipped.filter { $0.kind == .logs && $0.reason == .uncheckable }.map(\.provider)
            for provider in unique(unchecked) {
                let earlierDays = earlier.days.filter { $0.provider == provider }
                let earlierRoots = earlier.logRoots.filter { $0.provider == provider }
                guard !earlierDays.isEmpty || !earlierRoots.isEmpty else { continue }
                keptDays = keptDays.filter { $0.provider != provider } + earlierDays
                roots = roots.filter { $0.provider != provider } + earlierRoots
                readAt[provider] = earlier.time(of: provider)
            }
        }
        return Entry(distro: distro, timeZone: reading.timeZone, answeredAt: answeredAt, readAt: readAt,
                     logRoots: roots, days: keptDays)
    }

    /// The entries as they count now (design, Kept days count only while they
    /// still mean what they did; A log root two distros read counts once), in
    /// this order:
    ///
    /// 1. An entry counted in another zone than `zone` goes (every entry when
    ///    `zone` is nil): its labels are another zone's days.
    /// 2. A provider's days and log roots go from an entry when one of its log
    ///    roots for that provider overlaps one of `windows`' for it: Windows
    ///    reads that folder now.
    /// 3. For each provider, the entries left with a log root for it make
    ///    groups: two are in one when a root of the first overlaps one of the
    ///    second's, joined until no entry is added. A group counts the latest
    ///    reading of that provider (`readAt`), the first by `distro` on equal
    ///    times; every other entry of the group loses its days of it, keeping
    ///    its log roots, for `shared`.
    ///
    /// `entries` keeps the order it was given, with an entry left with no days.
    public static func current(_ entries: [Entry], zone: String?, windows: [ProviderRoots]) -> Counted {
        var leftOut: [String] = []
        var counted: [Entry] = []
        for entry in entries {
            guard let zone, entry.timeZone == zone else {
                leftOut.append("WSL \(entry.distro): kept days left out: counted in \(entry.timeZone), and Windows' zone is \(zone ?? "none") now")
                continue
            }
            var kept = entry
            for provider in unique(entry.logRoots.map(\.provider)) {
                let windowsLogs = windows.filter { $0.provider == provider }.flatMap(\.logs)
                let match = entry.logRoots.lazy.filter { $0.provider == provider }.compactMap { root in
                    windowsLogs.first { SharedRoots.overlaps(root.windowsPath, $0) }.map { (root: root.windowsPath, windows: $0) }
                }.first
                guard let match else { continue }
                leftOut.append("WSL \(entry.distro): kept \(provider) days left out: Windows reads \(match.windows) now, and they came from \(match.root)")
                kept = kept.dropping(provider, roots: true)
            }
            counted.append(kept)
        }

        var shared: [String: [SharedLog]] = [:]
        for provider in Set(counted.flatMap { $0.logRoots.map(\.provider) }).sorted() {
            let roots = counted.map { $0.logRoots.filter { $0.provider == provider }.map(\.windowsPath) }
            func overlap(_ a: Int, _ b: Int) -> Bool {
                roots[a].contains { root in roots[b].contains { SharedRoots.overlaps(root, $0) } }
            }
            var unplaced = counted.indices.filter { !roots[$0].isEmpty }
            while let first = unplaced.first {
                var group = [first]
                unplaced.removeFirst()
                var grew = true
                while grew {
                    grew = false
                    for other in unplaced where group.contains(where: { overlap($0, other) }) {
                        group.append(other)
                        unplaced.removeAll { $0 == other }
                        grew = true
                    }
                }
                guard group.count > 1 else { continue }
                let winner = group.min { a, b in
                    let (x, y) = (counted[a].time(of: provider), counted[b].time(of: provider))
                    return x != y ? x > y : counted[a].distro < counted[b].distro
                }!
                for member in group.sorted(by: { counted[$0].distro < counted[$1].distro }) {
                    let others = group.filter { $0 != member }
                    let distro = counted[member].distro
                    for root in roots[member] where others.contains(where: { roots[$0].contains { SharedRoots.overlaps(root, $0) } }) {
                        shared[distro, default: []].append(SharedLog(provider: provider, windowsPath: root,
                                                                     with: others.map { counted[$0].distro }.sorted()))
                    }
                    guard member != winner else { continue }
                    let root = roots[member].first { root in roots[winner].contains { SharedRoots.overlaps(root, $0) } }
                        ?? roots[member].first { root in others.contains { roots[$0].contains { SharedRoots.overlaps(root, $0) } } }
                        ?? roots[member][0]
                    leftOut.append("WSL \(distro): kept \(provider) days left out: \(root) is read by \(counted[winner].distro) too, and its reading is the latest")
                    counted[member] = counted[member].dropping(provider, roots: false)
                }
            }
        }
        return Counted(entries: counted, leftOut: leftOut, shared: shared)
    }

    /// One `LoginDays` per entry and provider, each kept day a stat
    /// (`stat(_:calendar:)`), only the labels from `range`'s first day to its
    /// last as `calendar` labels them.
    public static func logins(_ entries: [Entry], in range: DateRange, calendar: Calendar) -> [LoginDays] {
        let first = DailyTokens.day(of: range.first, calendar: calendar), last = DailyTokens.day(of: range.last, calendar: calendar)
        return entries.flatMap { entry in
            unique(entry.days.map(\.provider)).compactMap { provider -> LoginDays? in
                let stats = entry.days.filter { $0.provider == provider && $0.day >= first && $0.day <= last }
                    .compactMap { stat($0, calendar: calendar) }
                return stats.isEmpty ? nil : LoginDays(providerId: provider, days: stats)
            }
        }
    }

    /// A kept day as a stat: dated at its label's start in `calendar`, found
    /// through the label's noon, since a daylight saving change can skip a
    /// midnight. `totalTokens` is input, output and unsplit, so
    /// `DailyTokens(provider:stat:)` gives the same day back.
    static func stat(_ day: DailyTokens, calendar: Calendar) -> DailyUsageStat? {
        let parts = day.day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let noon = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return nil }
        return DailyUsageStat(date: calendar.startOfDay(for: noon), totalCost: 0,
                              totalTokens: day.input + day.output + day.unsplit, workingTime: 0, sessionCount: 0,
                              inputTokens: day.input, outputTokens: day.output,
                              cacheCreationTokens: day.cacheWrite, cacheReadTokens: day.cacheRead)
    }

    /// `values` in their first order, each once.
    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
