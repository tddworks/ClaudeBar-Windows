import Foundation
import Leaderboard
import Quotas
import Testing
@testable import ClaudeBarShared
@testable import ClaudeBarWindows

/// Each distro's days, kept on Windows (docs/plans/2026-11-03-wsl-design.md,
/// No day shrinks; Kept days count only while they still mean what they did;
/// A log root two distros read counts once). Explicit calendars, and a
/// folder of the test's own: no test reads this PC's kept days.
@Suite
struct WslKeptDaysTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cbw-kept-\(UUID().uuidString)", isDirectory: true)

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// Noon of a label in `calendar`.
    static func noon(_ label: String, _ calendar: Calendar) -> Date {
        let parts = label.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    /// The 30 days ending on `label`, as the uploader reads them.
    static func window(endingOn label: String, _ calendar: Calendar) -> DateRange {
        DateRange.last(30, endingOn: noon(label, calendar), calendar: calendar)
    }

    static func day(_ provider: String, _ label: String, _ input: Int, _ output: Int = 0, _ cacheWrite: Int = 0,
                    _ cacheRead: Int = 0, _ unsplit: Int = 0) -> DailyTokens {
        DailyTokens(provider: provider, day: label, input: input, output: output, cacheWrite: cacheWrite,
                    cacheRead: cacheRead, unsplit: unsplit)
    }

    /// 2026-11-12 at the given hour, UTC.
    static func at(_ hour: Int, day: Int = 12) -> Date {
        calendar("UTC").date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    static func entry(_ distro: String, zone: String = "Asia/Seoul", at answeredAt: Date = at(10),
                      roots: [(String, String)] = [], days: [DailyTokens], readAt: [String: Date]? = nil) -> WslKeptDays.Entry {
        let providers = Set(days.map(\.provider) + roots.map(\.0))
        return WslKeptDays.Entry(distro: distro, timeZone: zone, answeredAt: answeredAt,
                                 readAt: readAt ?? Dictionary(uniqueKeysWithValues: providers.map { ($0, answeredAt) }),
                                 logRoots: roots.map { ProbeReading.LogRoot(provider: $0.0, windowsPath: $0.1) }, days: days)
    }

    /// This PC's `claude` day of `input` tokens on `label`.
    static func pc(_ label: String, _ input: Int, _ calendar: Calendar) -> LoginDays {
        LoginDays(providerId: "claude", days: [DailyUsageStat(date: calendar.startOfDay(for: noon(label, calendar)), totalCost: 0,
                                                              totalTokens: input, workingTime: 0, sessionCount: 0, inputTokens: input)])
    }

    /// What an upload would send: the kept days as they count, with this PC's.
    static func summed(_ entries: [WslKeptDays.Entry], pc: [LoginDays] = [], providers: Set<String> = ["claude"],
                       endingOn label: String = "2026-11-12", calendar: Calendar = calendar("Asia/Seoul")) -> [DailyTokens] {
        let counted = WslKeptDays.current(entries, zone: "Asia/Seoul", windows: [])
        return DailyTokens.summed(WslKeptDays.logins(counted.entries, in: window(endingOn: label, calendar), calendar: calendar) + pc,
                                  providers: providers, calendar: calendar)
    }

    static var sampleURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../tests/wsl-kept-days.json").standardized
    }

    // MARK: - Kept days as logins

    @Test(arguments: ["UTC", "Asia/Seoul"])
    func `should give each kept day back through ClaudeBar's sum, labels and counts`(zone: String) {
        let calendar = Self.calendar(zone)
        let claude = Self.day("claude", "2026-11-11", 1, 2, 3, 4, 5), codex = Self.day("codex", "2026-11-11", 10, 0, 0, 0, 7)
        let entry = Self.entry("Ubuntu-26.04", days: [claude, codex])

        let logins = WslKeptDays.logins([entry], in: Self.window(endingOn: "2026-11-12", calendar), calendar: calendar)

        #expect(DailyTokens.summed(logins, providers: ["claude", "codex"], calendar: calendar) == [claude, codex])
    }

    @Test func `should add a kept day to this PC's day of the same label`() {
        let calendar = Self.calendar("Asia/Seoul")
        let entry = Self.entry("Ubuntu-26.04", days: [Self.day("claude", "2026-11-11", 1, 2, 3, 4, 5)])

        let logins = WslKeptDays.logins([entry], in: Self.window(endingOn: "2026-11-12", calendar), calendar: calendar)
            + [Self.pc("2026-11-11", 100, calendar)]

        #expect(DailyTokens.summed(logins, providers: ["claude"], calendar: calendar) == [Self.day("claude", "2026-11-11", 101, 2, 3, 4, 5)])
    }

    /// Daylight saving starts at midnight in Santiago on 2026-09-06: that day starts at 01:00.
    @Test func `should keep a day's label when its midnight doesn't exist`() {
        let calendar = Self.calendar("America/Santiago")
        let entry = Self.entry("Ubuntu-26.04", zone: "America/Santiago", days: [Self.day("claude", "2026-09-06", 7)])

        let logins = WslKeptDays.logins([entry], in: Self.window(endingOn: "2026-09-10", calendar), calendar: calendar)

        #expect(DailyTokens.summed(logins, providers: ["claude"], calendar: calendar).map(\.day) == ["2026-09-06"])
    }

    @Test func `should leave out a kept day outside the window`() {
        let calendar = Self.calendar("Asia/Seoul")
        let entry = Self.entry("Ubuntu-26.04", days: [Self.day("claude", "2026-10-03", 7), Self.day("claude", "2026-11-12", 8)])

        let logins = WslKeptDays.logins([entry], in: Self.window(endingOn: "2026-11-12", calendar), calendar: calendar)

        #expect(DailyTokens.summed(logins, providers: ["claude"], calendar: calendar).map(\.day) == ["2026-11-12"])
    }

    // MARK: - The store

    @Test func `should give a saved entry back, a second save replacing it, a file that doesn't decode left out`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = WslKeptDays(folder: folder)
        let first = Self.entry("Ubuntu-26.04", days: [Self.day("claude", "2026-11-11", 1)])
        let second = Self.entry("Ubuntu-26.04", at: Self.at(11), days: [Self.day("claude", "2026-11-11", 2)])
        let spaced = Self.entry("My Distro", roots: [("claude", #"D:\shared\.claude\projects"#)], days: [Self.day("claude", "2026-11-11", 3)])

        try kept.save(first)
        #expect(kept.all() == [first])
        try kept.save(second)
        try kept.save(spaced)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("Broken.json"))

        #expect(kept.all() == [spaced, second])
        #expect(kept.entry(for: "Ubuntu-26.04") == second)
        #expect(kept.entry(for: "My Distro") == spaced)
        #expect(kept.entry(for: "Broken") == nil)
        #expect(kept.entry(for: "Debian") == nil)
    }

    @Test func `should have nothing kept when the folder isn't there`() {
        #expect(WslKeptDays(folder: folder).all().isEmpty)
    }

    @Test func `should read the checked-in sample as the contract's entry, and write it back byte for byte`() throws {
        let data = try Data(contentsOf: Self.sampleURL)
        let entry = try ProbeReading.decoder().decode(WslKeptDays.Entry.self, from: data)

        let answered = Date(timeIntervalSince1970: 1_794_470_400)
        #expect(entry == WslKeptDays.Entry(
            distro: "Ubuntu-26.04", timeZone: "Asia/Seoul", answeredAt: answered, readAt: ["claude": answered],
            logRoots: [.init(provider: "claude", windowsPath: #"\\wsl.localhost\Ubuntu-26.04\home\josh\.claude\projects"#)],
            days: [Self.day("claude", "2026-11-11", 1, 2, 3, 4, 0)]))
        let text = String(decoding: try ProbeReading.encoder().encode(entry), as: UTF8.self)
        #expect(text == String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines))
    }

    // MARK: - What a run keeps

    private func reading(_ days: [DailyTokens]?, zone: String = "Asia/Seoul", roots: [(String, String)] = [],
                         skipped: [ProbeReading.Skip] = []) -> ProbeReading {
        ProbeReading(version: ClientVersion.version, hud: nil, days: days, tools: [], skipped: skipped,
                     logRoots: roots.map { ProbeReading.LogRoot(provider: $0.0, windowsPath: $0.1) }, timeZone: zone, timedOut: false,
                     environmentImport: .init(state: .imported, names: [], reason: nil), diagnostics: [])
    }

    @Test func `should keep a run's days and roots, each provider read when it answered`() {
        let days = [Self.day("claude", "2026-11-11", 1), Self.day("codex", "2026-11-11", 2)]
        let roots = [("claude", #"D:\shared\.claude\projects"#), ("codex", #"\\wsl.localhost\U\home\me\.codex\sessions"#)]

        let entry = WslKeptDays.entry(distro: "U", reading: reading(days, roots: roots), days: days, answeredAt: Self.at(11), earlier: nil)

        #expect(entry == Self.entry("U", at: Self.at(11), roots: roots, days: days))
    }

    @Test func `should keep a root's days from before when the run couldn't check it, in the same zone`() {
        let claudeRoot = ("claude", #"D:\shared\.claude\projects"#)
        let earlier = Self.entry("U", at: Self.at(10), roots: [claudeRoot], days: [Self.day("claude", "2026-11-11", 5)])
        let codex = [Self.day("codex", "2026-11-11", 2)]
        let codexRoot = ("codex", #"\\wsl.localhost\U\home\me\.codex\sessions"#)
        let unchecked = reading(codex, roots: [codexRoot],
                                skipped: [.init(provider: "claude", kind: .logs, windowsPath: nil, reason: .uncheckable)])

        let entry = WslKeptDays.entry(distro: "U", reading: unchecked, days: codex, answeredAt: Self.at(11), earlier: earlier)

        #expect(entry.days.sorted { $0.provider < $1.provider } == [Self.day("claude", "2026-11-11", 5)] + codex)
        #expect(Set(entry.logRoots.map(\.windowsPath)) == [claudeRoot.1, codexRoot.1])
        #expect(entry.readAt == ["claude": Self.at(10), "codex": Self.at(11)])
        #expect(entry.answeredAt == Self.at(11))

        let shared = reading(codex, roots: [codexRoot],
                             skipped: [.init(provider: "claude", kind: .logs, windowsPath: #"D:\shared\.claude"#, reason: .shared)])
        let elsewhere = Self.entry("U", zone: "America/Los_Angeles", at: Self.at(10), roots: [claudeRoot],
                                   days: [Self.day("claude", "2026-11-11", 5)])
        for (answer, before) in [(shared, Optional(earlier)), (unchecked, Optional(elsewhere)), (unchecked, nil)] {
            let kept = WslKeptDays.entry(distro: "U", reading: answer, days: codex, answeredAt: Self.at(11), earlier: before)
            #expect(kept == Self.entry("U", at: Self.at(11), roots: [codexRoot], days: codex))
        }
    }

    // MARK: - What counts now

    @Test func `should leave out kept days counted in another zone than Windows' now, all of them when it has no name`() {
        let seoul = Self.entry("Debian", days: [Self.day("claude", "2026-11-11", 1)])
        let angeles = Self.entry("Ubuntu-26.04", zone: "America/Los_Angeles", days: [Self.day("claude", "2026-11-11", 2)])

        let counted = WslKeptDays.current([seoul, angeles], zone: "Asia/Seoul", windows: [])
        #expect(counted.entries == [seoul])
        #expect(counted.leftOut == ["WSL Ubuntu-26.04: kept days left out: counted in America/Los_Angeles, and Windows' zone is Asia/Seoul now"])

        let none = WslKeptDays.current([seoul, angeles], zone: nil, windows: [])
        #expect(none.entries.isEmpty)
        #expect(none.leftOut == ["WSL Debian: kept days left out: counted in Asia/Seoul, and Windows' zone is none now",
                                 "WSL Ubuntu-26.04: kept days left out: counted in America/Los_Angeles, and Windows' zone is none now"])
    }

    @Test func `should leave out a provider's kept days whose root this PC reads now, that provider's only`() {
        let codexRoot = #"\\wsl.localhost\Ubuntu-26.04\home\me\.codex\sessions"#
        let entry = Self.entry("Ubuntu-26.04", roots: [("claude", #"C:\Users\me\wsl-claude\projects"#), ("codex", codexRoot)],
                               days: [Self.day("claude", "2026-11-11", 1), Self.day("codex", "2026-11-11", 2)])

        let read = WslKeptDays.current([entry], zone: "Asia/Seoul",
                                       windows: [ProviderRoots(provider: "claude", credentials: [], logs: [#"C:\Users\me\wsl-claude"#])])
        #expect(read.entries.map(\.days) == [[Self.day("codex", "2026-11-11", 2)]])
        #expect(read.entries.map(\.logRoots) == [[.init(provider: "codex", windowsPath: codexRoot)]])
        #expect(read.leftOut == [#"WSL Ubuntu-26.04: kept claude days left out: Windows reads C:\Users\me\wsl-claude now, and they came from C:\Users\me\wsl-claude\projects"#])

        let other = WslKeptDays.current([entry], zone: "Asia/Seoul",
                                        windows: [ProviderRoots(provider: "codex", credentials: [], logs: [#"C:\Users\me\wsl-claude"#])])
        #expect(other.entries == [entry])
        #expect(other.leftOut.isEmpty)
    }

    private static let shared = #"D:\shared\.claude\projects"#

    @Test func `should count the latest reading of a folder two distros read, and say which went`() {
        let ubuntu = Self.entry("Ubuntu", at: Self.at(10), roots: [("claude", Self.shared)], days: [Self.day("claude", "2026-11-10", 100)])
        let debian = Self.entry("Debian", at: Self.at(11), roots: [("claude", Self.shared)], days: [Self.day("claude", "2026-11-10", 120)])

        #expect(Self.summed([debian, ubuntu], pc: [Self.pc("2026-11-10", 5, Self.calendar("Asia/Seoul"))])
                == [Self.day("claude", "2026-11-10", 125)])
        #expect(WslKeptDays.current([debian, ubuntu], zone: "Asia/Seoul", windows: []).leftOut
                == [#"WSL Ubuntu: kept claude days left out: D:\shared\.claude\projects is read by Debian too, and its reading is the latest"#])
    }

    /// A tool deleted lines in between: the newer reading is what one reader of that folder would send.
    @Test func `should count a newer, smaller reading, never the larger older one`() {
        let debian = Self.entry("Debian", at: Self.at(10), roots: [("claude", Self.shared)], days: [Self.day("claude", "2026-11-10", 120)])
        let ubuntu = Self.entry("Ubuntu", at: Self.at(11), roots: [("claude", Self.shared)], days: [Self.day("claude", "2026-11-10", 30)])

        #expect(Self.summed([debian, ubuntu], pc: [Self.pc("2026-11-10", 5, Self.calendar("Asia/Seoul"))])
                == [Self.day("claude", "2026-11-10", 35)])
    }

    @Test func `should count the first by name when two were read at the same second, in either order`() {
        let debian = Self.entry("Debian", at: Self.at(10), roots: [("claude", Self.shared)], days: [Self.day("claude", "2026-11-10", 100, 1)])
        let ubuntu = Self.entry("Ubuntu", at: Self.at(10), roots: [("claude", Self.shared)], days: [Self.day("claude", "2026-11-10", 100, 2)])

        #expect(Self.summed([debian, ubuntu]) == [Self.day("claude", "2026-11-10", 100, 1)])
        #expect(Self.summed([ubuntu, debian]) == [Self.day("claude", "2026-11-10", 100, 1)])
    }

    @Test func `should take every day of a provider from the latest reading, not the largest day`() {
        let ubuntu = Self.entry("Ubuntu", at: Self.at(11), roots: [("claude", Self.shared)],
                                days: [Self.day("claude", "2026-11-09", 80), Self.day("claude", "2026-11-10", 100)])
        let debian = Self.entry("Debian", at: Self.at(10), roots: [("claude", Self.shared)],
                                days: [Self.day("claude", "2026-11-09", 60), Self.day("claude", "2026-11-10", 120)])

        #expect(Self.summed([debian, ubuntu]) == [Self.day("claude", "2026-11-09", 80), Self.day("claude", "2026-11-10", 100)])
    }

    @Test func `should group distros through another, one inside the next`() {
        let ubuntu = Self.entry("Ubuntu", at: Self.at(10), roots: [("claude", #"D:\shared\.claude"#)], days: [Self.day("claude", "2026-11-10", 1)])
        let debian = Self.entry("Debian", at: Self.at(11), roots: [("claude", Self.shared)], days: [Self.day("claude", "2026-11-10", 2)])
        let alpine = Self.entry("Alpine", at: Self.at(12), roots: [("claude", #"D:\shared"#)], days: [Self.day("claude", "2026-11-10", 4)])

        #expect(Self.summed([alpine, debian, ubuntu]) == [Self.day("claude", "2026-11-10", 4)])
    }

    /// `D:\shared\one` and `D:\shared\two` don't overlap; `D:\shared` overlaps both.
    @Test func `should group two distros that overlap only through a third`() {
        let one = Self.entry("Debian", at: Self.at(10), roots: [("claude", #"D:\shared\one"#)], days: [Self.day("claude", "2026-11-10", 1)])
        let two = Self.entry("Ubuntu", at: Self.at(11), roots: [("claude", #"D:\shared\two"#)], days: [Self.day("claude", "2026-11-10", 2)])
        let all = Self.entry("Alpine", at: Self.at(9), roots: [("claude", #"D:\shared"#)], days: [Self.day("claude", "2026-11-10", 4)])

        #expect(Self.summed([all, one, two]) == [Self.day("claude", "2026-11-10", 2)])
        #expect(Self.summed([one, two]) == [Self.day("claude", "2026-11-10", 3)])
    }

    @Test func `should not group another provider's root in the same folder`() {
        let debian = Self.entry("Debian", at: Self.at(10), roots: [("codex", Self.shared)], days: [Self.day("codex", "2026-11-10", 7)])
        let ubuntu = Self.entry("Ubuntu", at: Self.at(11), roots: [("claude", Self.shared)], days: [Self.day("claude", "2026-11-10", 2)])

        #expect(Self.summed([debian, ubuntu], providers: ["claude", "codex"])
                == [Self.day("claude", "2026-11-10", 2), Self.day("codex", "2026-11-10", 7)])
        #expect(WslKeptDays.current([debian, ubuntu], zone: "Asia/Seoul", windows: []).shared.isEmpty)
    }

    @Test func `should add up two distros' folders that don't overlap`() {
        let debian = Self.entry("Debian", at: Self.at(10), roots: [("claude", #"D:\one\.claude\projects"#)], days: [Self.day("claude", "2026-11-10", 7)])
        let ubuntu = Self.entry("Ubuntu", at: Self.at(11), roots: [("claude", #"D:\two\.claude\projects"#)], days: [Self.day("claude", "2026-11-10", 2)])

        #expect(Self.summed([debian, ubuntu]) == [Self.day("claude", "2026-11-10", 9)])
    }

    /// The design's undercount: a reading of a shared folder and a distro's own counts whole, or not at all.
    @Test func `should count one reading of a distro whose roots are a shared folder and its own, never both`() {
        let debianOwn = #"\\wsl.localhost\Debian\home\me\.claude\projects"#
        func debian(_ hour: Int) -> WslKeptDays.Entry {
            Self.entry("Debian", at: Self.at(hour), roots: [("claude", Self.shared), ("claude", debianOwn)], days: [Self.day("claude", "2026-11-10", 150)])
        }
        func ubuntu(_ hour: Int) -> WslKeptDays.Entry {
            Self.entry("Ubuntu", at: Self.at(hour), roots: [("claude", Self.shared)], days: [Self.day("claude", "2026-11-10", 100)])
        }

        #expect(Self.summed([debian(10), ubuntu(11)]) == [Self.day("claude", "2026-11-10", 100)])
        #expect(Self.summed([debian(11), ubuntu(10)]) == [Self.day("claude", "2026-11-10", 150)])
    }

    @Test func `should leave out another zone's entry and a root this PC reads before grouping`() {
        let ubuntu = Self.entry("Ubuntu", at: Self.at(10), roots: [("claude", Self.shared)], days: [Self.day("claude", "2026-11-10", 100)])
        let angeles = Self.entry("Debian", zone: "America/Los_Angeles", at: Self.at(11), roots: [("claude", Self.shared)],
                                 days: [Self.day("claude", "2026-11-10", 120)])
        let read = Self.entry("Debian", at: Self.at(11), roots: [("claude", #"C:\Users\me\.claude\projects"#), ("claude", Self.shared)],
                              days: [Self.day("claude", "2026-11-10", 120)])

        let zoned = WslKeptDays.current([angeles, ubuntu], zone: "Asia/Seoul", windows: [])
        #expect(zoned.entries == [ubuntu])
        #expect(zoned.shared.isEmpty)
        let windows = [ProviderRoots(provider: "claude", credentials: [], logs: [#"C:\Users\me\.claude"#])]
        let rooted = WslKeptDays.current([read, ubuntu], zone: "Asia/Seoul", windows: windows)
        #expect(rooted.entries.last == ubuntu)
        #expect(rooted.entries.first?.days == [])
        #expect(rooted.shared.isEmpty)
    }

    /// The kept files behind tests/wsl-reply.json (the plan's *The HUD reply's `wsl`*).
    static func replyEntries() -> [WslKeptDays.Entry] {
        let seoul = calendar("Asia/Seoul")
        func at(_ hour: Int) -> Date { seoul.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: hour))! }
        return [
            entry("Debian", at: at(10), roots: [("claude", #"D:\shared\.claude\projects"#), ("codex", #"\\wsl.localhost\Debian\home\me\.codex\sessions"#)],
                  days: [day("claude", "2026-11-11", 10), day("codex", "2026-11-11", 20)]),
            entry("Ubuntu-26.04", at: at(11), roots: [("claude", #"D:\shared\.claude"#), ("omp", #"\\wsl.localhost\Ubuntu-26.04\home\me\.omp\agent\sessions"#)],
                  days: [day("claude", "2026-11-11", 30), day("omp", "2026-11-11", 40)]),
        ]
    }

    @Test func `should give each distro of a group the roots it shares and with whom, as the HUD reply's sample has them`() {
        let counted = WslKeptDays.current(Self.replyEntries(), zone: "Asia/Seoul", windows: [])

        #expect(counted.shared == [
            "Debian": [.init(provider: "claude", windowsPath: #"D:\shared\.claude\projects"#, with: ["Ubuntu-26.04"])],
            "Ubuntu-26.04": [.init(provider: "claude", windowsPath: #"D:\shared\.claude"#, with: ["Debian"])],
        ])
        #expect(counted.shared["Alpine"] == nil)
        #expect(counted.entries.map { Set($0.days.map(\.provider)) } == [["codex"], ["claude", "omp"]])
    }
}
