import Foundation
import Leaderboard
import Testing
@testable import ClaudeBarWindows

/// The membership's record on disk, which the app and the hourly uploader,
/// separate processes, both read and write.
@Suite
struct SettingsFileTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cbw-\(UUID().uuidString)", isDirectory: true)
    private var url: URL { folder.appendingPathComponent("settings.json") }
    private var lockName: String { #"Local\ClaudeBar.test."# + folder.lastPathComponent }

    private func file() -> SettingsFile { SettingsFile(url: url, lockName: lockName) }

    private let record = LeaderboardRecord(
        username: "tokenwhale", sharing: ["omp", "claude"], visible: false, lastUpload: Date(timeIntervalSince1970: 1_791_692_409.532),
        sharesCountry: true, globeHintDismissed: true, link: ProfileLink(platform: .github, handle: "octocat"),
        refused: [RefusedDay(provider: "omp", day: "2026-10-10", reason: "cap")], shownDevices: ["k2", "k1"])

    @Test func `should read the record back exactly in another process's file, as after a restart`() {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)

        #expect(file().leaderboardRecord() == record)
    }

    @Test func `should forget the record on nil, and keep the switch apart from it`() {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        file().setLeaderboardOn(false)

        file().saveLeaderboardRecord(nil)

        #expect(file().leaderboardRecord() == nil)
        #expect(!file().isLeaderboardOn())
    }

    @Test func `should be on, with no record, before anything was saved or when the file is damaged`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(file().leaderboardRecord() == nil && file().isLeaderboardOn())

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)

        #expect(file().leaderboardRecord() == nil && file().isLeaderboardOn())
    }

    /// Two writers at once, as the app and the uploader can be: the file is
    /// never half written, and each field holds what one of them saved.
    @Test func `should keep the file whole while two writers save at once`() async {
        defer { try? FileManager.default.removeItem(at: folder) }
        let records = (0..<2).map { writer in
            LeaderboardRecord(username: "writer\(writer)", sharing: ["omp"], visible: true,
                              lastUpload: Date(timeIntervalSince1970: Double(writer)))
        }
        let url = url, lockName = lockName
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<2 {
                group.addTask {
                    let file = SettingsFile(url: url, lockName: lockName)
                    for round in 0..<50 {
                        file.saveLeaderboardRecord(records[writer])
                        file.setLeaderboardOn(round % 2 == 0)
                    }
                }
            }
        }

        let saved = file().leaderboardRecord()
        #expect(saved.map { records.contains($0) } == true)
    }

    // MARK: - Each membership saves only what it changed

    /// The app and the hourly uploader each read the record, then each change
    /// a different part of it: both changes stay, whichever saves last.
    @Test func `should keep what each of two processes changed, when both save from the same read`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        let app = file(), uploader = file()
        let read = try #require(app.leaderboardRecord())
        _ = uploader.leaderboardRecord()
        let later = Date(timeIntervalSince1970: 1_791_700_000)

        app.saveLeaderboardRecord(read.with(sharing: ["claude"], visible: true))
        uploader.saveLeaderboardRecord(read.with(lastUpload: later, refused: []))

        #expect(file().leaderboardRecord() == read.with(sharing: ["claude"], visible: true, lastUpload: later, refused: []))
    }

    /// A membership that left while the uploader was running stays gone: the
    /// uploader's save, from before, doesn't bring it back.
    @Test func `should not bring back a membership that left, from a save made before it did`() {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        let uploader = file()
        _ = uploader.leaderboardRecord()

        file().saveLeaderboardRecord(nil)
        uploader.saveLeaderboardRecord(record.with(lastUpload: Date(timeIntervalSince1970: 1_791_700_000)))

        #expect(file().leaderboardRecord() == nil)
    }

    /// Left and joined again, as someone else: a late save from the old
    /// membership, its record or its forgetting, leaves the new one alone.
    @Test func `should leave a membership joined after another alone, when the one before saves late`() {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        let late = file()
        _ = late.leaderboardRecord()
        let next = LeaderboardRecord(username: "newwhale", sharing: ["claude"], visible: true, lastUpload: nil)

        file().saveLeaderboardRecord(nil)
        file().saveLeaderboardRecord(next)
        late.saveLeaderboardRecord(record.with(lastUpload: Date(timeIntervalSince1970: 1_791_700_000)))
        late.saveLeaderboardRecord(nil)

        #expect(file().leaderboardRecord() == next)
    }
}

extension LeaderboardRecord {
    /// This record with some fields changed.
    func with(sharing: [String]? = nil, visible: Bool? = nil, lastUpload: Date?? = nil, refused: [RefusedDay]? = nil) -> LeaderboardRecord {
        LeaderboardRecord(username: username, sharing: sharing ?? self.sharing, visible: visible ?? self.visible,
                          lastUpload: lastUpload ?? self.lastUpload, sharesCountry: sharesCountry,
                          globeHintDismissed: globeHintDismissed, link: link, refused: refused ?? self.refused,
                          shownDevices: shownDevices)
    }
}
