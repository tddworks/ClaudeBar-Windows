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
    /// always one whole record, never a mix or a half.
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
}
