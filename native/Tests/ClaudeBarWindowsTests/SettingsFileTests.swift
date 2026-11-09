import Diagnostics
import Foundation
import Leaderboard
import Testing
import WinSDK
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
        refused: [RefusedDay(provider: "omp", day: "2026-10-10", reason: "cap")], shownDevices: ["k2", "k1"],
        machine: "3f1a9c", addedAsDevice: true)

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

    /// A program this process starts, as the app starts `schtasks.exe` or a
    /// test `cmd.exe`, gets a copy of every handle the process lets children
    /// inherit. A copy of the new file a save was writing kept the save from
    /// moving it into place (Win32 error 32, a sharing violation), and the
    /// save was lost, its new file left beside the settings.
    @Test func `should save every time while this process starts programs`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let starting = Starting()
        let starters = DispatchGroup()
        for _ in 0..<4 {
            starters.enter()
            Thread.detachNewThread {
                while starting.isOn {
                    let program = Process()
                    program.executableURL = URL(fileURLWithPath: #"C:\Windows\System32\cmd.exe"#)
                    program.arguments = ["/c", "exit"]
                    program.standardOutput = FileHandle.nullDevice
                    try? program.run()
                    program.waitUntilExit()
                }
                starters.leave()
            }
        }
        let view = file()
        var lost: [String] = []
        for round in 0..<300 {
            view.saveLeaderboardRecord(record.with(lastUpload: Date(timeIntervalSince1970: Double(round))))
            if let failure = view.takeFailure() { lost.append(failure) }
        }
        starting.stop()
        starters.wait()

        #expect(lost == [])
        #expect(file().leaderboardRecord() == record.with(lastUpload: Date(timeIntervalSince1970: 299)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["settings.json"])
    }

    /// Another program reading the file for a moment without letting it be
    /// replaced: the save waits for it rather than being lost.
    @Test func `should save over the file while another program holds it open for a moment`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        let view = file()
        _ = view.leaderboardRecord()
        let opened = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), 0, nil)
        }
        let held = try #require(opened.flatMap { $0 == INVALID_HANDLE_VALUE ? nil : UInt(bitPattern: $0) })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { CloseHandle(HANDLE(bitPattern: held)) }

        view.saveLeaderboardRecord(record.with(visible: true))

        #expect(view.takeFailure() == nil)
        #expect(file().leaderboardRecord() == record.with(visible: true))
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

    /// The app records which machine the key is on (on first launch, or when
    /// the person keeps a copied key here) while an upload, from an earlier
    /// read, records itself: the machine stays, or the next launch would take
    /// the key for a copy, or forget it is one.
    @Test func `should keep the machine one process recorded when the other saves an upload from an earlier read`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record.with(machine: nil))
        let app = file(), uploader = file()
        let read = try #require(app.leaderboardRecord())
        _ = uploader.leaderboardRecord()
        let later = Date(timeIntervalSince1970: 1_791_700_000)

        app.saveLeaderboardRecord(read.with(machine: "7b20e4"))
        uploader.saveLeaderboardRecord(read.with(lastUpload: later))

        #expect(file().leaderboardRecord() == read.with(lastUpload: later, machine: "7b20e4"))
    }

    /// A settings file this client wrote before it kept the machine: the
    /// membership is still read, with no machine and not an added device.
    @Test func `should still read a membership saved before the machine was kept`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"""
        {
          "generation" : 1,
          "leaderboard" : {
            "globeHintDismissed" : false, "refused" : [], "sharesCountry" : false, "sharing" : [ "omp" ],
            "shownDevices" : [], "username" : "tokenwhale", "visible" : true
          }
        }
        """#.utf8).write(to: url)

        #expect(file().leaderboardRecord() == LeaderboardRecord(username: "tokenwhale", sharing: ["omp"], visible: true, lastUpload: nil))
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

    /// ClaudeBar's package saves without throwing, so the file says when a save
    /// didn't land, and the same membership's next save still writes its change.
    @Test func `should say a save didn't reach the file, and write the change on the next save`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // A file where the settings folder should be: the folder can't be made.
        let blocked = folder.appendingPathComponent("ClaudeBar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: blocked)
        let view = SettingsFile(url: blocked.appendingPathComponent("settings.json"), lockName: lockName)
        _ = view.leaderboardRecord()

        view.saveLeaderboardRecord(record)

        #expect(view.takeFailure() != nil)
        #expect(view.takeFailure() == nil)

        try FileManager.default.removeItem(at: blocked)
        view.saveLeaderboardRecord(record)

        #expect(view.takeFailure() == nil)
        #expect(SettingsFile(url: blocked.appendingPathComponent("settings.json"), lockName: lockName).leaderboardRecord() == record)
    }

    /// A test that makes a save fail on purpose logs the failure like the app
    /// does: into the test run's own log, never the person's, where it would
    /// read as a save the app lost.
    @Test func `should log a save that failed on purpose to the test run's own log, not the person's`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let person = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("ClaudeBar/Logs/ClaudeBar.log")
        let failed = "Leaderboard settings could not be saved"
        let personBefore = Self.lines(in: person, containing: failed)
        let ownBefore = Self.lines(in: AppLog.logFileURL, containing: failed)
        let blocked = folder.appendingPathComponent("ClaudeBar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: blocked)
        let view = SettingsFile(url: blocked.appendingPathComponent("settings.json"), lockName: lockName)

        view.saveLeaderboardRecord(record)

        #expect(view.takeFailure() != nil)
        // The log writes on its own queue: wait for the line to land.
        let deadline = Date().addingTimeInterval(10)
        while Self.lines(in: AppLog.logFileURL, containing: failed) == ownBefore, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(Self.lines(in: AppLog.logFileURL, containing: failed) > ownBefore)
        #expect(Self.lines(in: person, containing: failed) == personBefore)
        #expect(AppLog.logFileURL.standardizedFileURL.path != person.standardizedFileURL.path)
    }

    private static func lines(in log: URL, containing text: String) -> Int {
        guard let data = try? Data(contentsOf: log) else { return 0 }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains(text) }.count
    }
}

/// Whether the test is still starting programs.
private final class Starting: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true

    var isOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return on
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        on = false
    }
}

extension LeaderboardRecord {
    /// This record with some fields changed.
    func with(sharing: [String]? = nil, visible: Bool? = nil, lastUpload: Date?? = nil, refused: [RefusedDay]? = nil,
              machine: String?? = nil) -> LeaderboardRecord {
        LeaderboardRecord(username: username, sharing: sharing ?? self.sharing, visible: visible ?? self.visible,
                          lastUpload: lastUpload ?? self.lastUpload, sharesCountry: sharesCountry,
                          globeHintDismissed: globeHintDismissed, link: link, refused: refused ?? self.refused,
                          shownDevices: shownDevices, machine: machine ?? self.machine, addedAsDevice: addedAsDevice)
    }
}
