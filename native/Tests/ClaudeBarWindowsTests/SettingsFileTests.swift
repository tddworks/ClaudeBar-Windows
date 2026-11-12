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
        machine: "3f1a9c", addedAsDevice: true,
        sent: [SentDay(provider: "omp", day: "2026-11-05", total: 100), SentDay(provider: "claude", day: "2026-11-05", total: 40)],
        heldBefore: "2026-11-01")

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

    // MARK: - What the server took (`sent`, `heldBefore`)

    /// ClaudeBar keeps what the server took of each day apart from no record
    /// of it: a record without `sent` is one from before it was kept, whose
    /// earlier days are held, while an empty one holds none.
    @Test func `should read an empty sent back as empty, apart from a record from before it was kept`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record.with(sent: .some([]), heldBefore: .some(nil)))

        #expect(file().leaderboardRecord()?.sent == [])
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(#""sent" : ["#))

        file().saveLeaderboardRecord(nil)
        file().saveLeaderboardRecord(record.with(sent: .some(nil), heldBefore: .some(nil)))

        #expect(file().leaderboardRecord().map { $0.sent == nil } == true)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(#""sent""#))
    }

    /// The app and the hourly uploader each upload and record what the server
    /// took, from the same read: the days each recorded both stay, or one
    /// would read as a day the server holds nothing of.
    @Test func `should keep the days each of two processes recorded, when both save from the same read`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        let app = file(), uploader = file()
        let read = try #require(app.leaderboardRecord())
        _ = uploader.leaderboardRecord()
        let earlier = read.sent ?? []

        app.saveLeaderboardRecord(read.with(sent: earlier + [SentDay(provider: "omp", day: "2026-11-06", total: 70)]))
        uploader.saveLeaderboardRecord(read.with(sent: earlier + [SentDay(provider: "claude", day: "2026-11-07", total: 30)]))

        #expect(file().leaderboardRecord()?.sent == (earlier + [SentDay(provider: "omp", day: "2026-11-06", total: 70),
                                                                 SentDay(provider: "claude", day: "2026-11-07", total: 30)]).sorted())
    }

    /// Both processes send the same day, read at different times: which
    /// answer reached the server last isn't known here, so the larger total
    /// stays, and a day read smaller than it is never sent to lower it.
    @Test(arguments: [(200, 150), (150, 200)])
    func `should keep the larger total of a day two processes both recorded`(_ first: Int, _ late: Int) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        let one = file(), other = file()
        let read = try #require(one.leaderboardRecord())
        _ = other.leaderboardRecord()
        func taken(_ total: Int) -> [SentDay] {
            (read.sent ?? []).map { $0.provider == "omp" ? SentDay(provider: "omp", day: $0.day, total: total) : $0 }
        }

        one.saveLeaderboardRecord(read.with(sent: taken(first)))
        other.saveLeaderboardRecord(read.with(sent: taken(late)))

        #expect(file().leaderboardRecord()?.sent == taken(max(first, late)).sorted())
    }

    /// A day leaves `sent` two days after it leaves the thirty: a process
    /// whose read still had it, saving later, doesn't bring it back, in
    /// either order.
    @Test func `should keep a day dropped from sent dropped, when the other process saves from an earlier read`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        let dropping = file(), late = file()
        let read = try #require(dropping.leaderboardRecord())
        _ = late.leaderboardRecord()
        let kept = (read.sent ?? []).filter { $0.provider == "claude" }
        let today = SentDay(provider: "omp", day: "2026-12-07", total: 5)

        dropping.saveLeaderboardRecord(read.with(sent: kept))
        late.saveLeaderboardRecord(read.with(sent: (read.sent ?? []) + [today]))

        #expect(file().leaderboardRecord()?.sent == (kept + [today]).sorted())

        // And the other way round: the file still has it, the one saving dropped it.
        file().saveLeaderboardRecord(nil)
        file().saveLeaderboardRecord(record)
        let first = file(), second = file()
        let again = try #require(first.leaderboardRecord())
        _ = second.leaderboardRecord()
        first.saveLeaderboardRecord(again.with(sent: (again.sent ?? []) + [today]))
        second.saveLeaderboardRecord(again.with(sent: kept))

        #expect(file().leaderboardRecord()?.sent == (kept + [today]).sorted())
    }

    /// Leaving forgets what the server took: an upload's record, from before,
    /// brings back neither the membership nor its days, after a new join either.
    @Test func `should not bring back the days of a membership that left, from a save made before it did`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        let uploader = file()
        let read = try #require(uploader.leaderboardRecord())
        let next = LeaderboardRecord(username: "tokenwhale", sharing: ["omp"], visible: true, lastUpload: nil, sent: [])

        file().saveLeaderboardRecord(nil)
        file().saveLeaderboardRecord(next)
        uploader.saveLeaderboardRecord(read.with(sent: (read.sent ?? []) + [SentDay(provider: "omp", day: "2026-11-06", total: 70)]))

        #expect(file().leaderboardRecord() == next)
    }

    /// *Make this PC its own device* gives the membership a new key, and with
    /// it a new `machine`; the server holds nothing of the new key's days, so
    /// `sent` starts empty. A process still on the old key, saving later,
    /// brings none of the old key's days into it.
    @Test func `should not carry days taken under the old key into the new key's sent`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        let app = file(), uploader = file()
        let read = try #require(app.leaderboardRecord())
        _ = uploader.leaderboardRecord()
        let ownDevice = read.with(machine: "9d0e57", sent: [], heldBefore: "2026-11-12")

        app.saveLeaderboardRecord(ownDevice)
        uploader.saveLeaderboardRecord(read.with(sent: (read.sent ?? []) + [SentDay(provider: "omp", day: "2026-11-11", total: 70)],
                                                 heldBefore: .some(nil)))

        #expect(file().leaderboardRecord()?.sent == [])
        #expect(file().leaderboardRecord()?.heldBefore == "2026-11-12")
    }

    /// Both processes hold the earlier days from a different day (each held
    /// them from its own read of the last upload, after the update): the
    /// later day stays, holding more. A held day goes only when refused, so
    /// holding one too many delays it; holding one too few could send it
    /// smaller than the server holds.
    @Test func `should hold the earlier days from the later day, when two processes held them from different days`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record.with(sent: .some(nil), heldBefore: .some(nil)))
        let app = file(), uploader = file()
        let read = try #require(app.leaderboardRecord())
        _ = uploader.leaderboardRecord()

        uploader.saveLeaderboardRecord(read.with(sent: [], heldBefore: "2026-11-12"))
        app.saveLeaderboardRecord(read.with(sent: [], heldBefore: "2026-11-11"))

        #expect(file().leaderboardRecord()?.heldBefore == "2026-11-12")
        #expect(file().leaderboardRecord()?.sent == [])
    }

    /// A process that changed nothing of them leaves `sent` and `heldBefore`
    /// as the file has them, the other's change included: once the earlier
    /// days are far enough back, an upload stops holding them.
    @Test func `should keep what the other process changed of sent and heldBefore, when this one changed neither`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        file().saveLeaderboardRecord(record)
        let app = file(), uploader = file()
        let read = try #require(app.leaderboardRecord())
        _ = uploader.leaderboardRecord()
        let taken = [SentDay(provider: "omp", day: "2026-12-07", total: 5)]

        uploader.saveLeaderboardRecord(read.with(sent: taken, heldBefore: .some(nil)))
        app.saveLeaderboardRecord(read.with(visible: true))

        #expect(file().leaderboardRecord() == read.with(visible: true, sent: taken, heldBefore: .some(nil)))
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
        // The log writes on one queue, in order, and the folder test fails a
        // save with the same words meanwhile: a line only this test writes,
        // after the save's, is in the file only once the save's line is.
        let marker = "SettingsFileTests marker \(UUID().uuidString)"
        AppLog.ui.info(marker)

        #expect(view.takeFailure() != nil)
        let deadline = Date().addingTimeInterval(10)
        while Self.lines(in: AppLog.logFileURL, containing: marker) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(Self.lines(in: AppLog.logFileURL, containing: marker) == 1)
        #expect(Self.lines(in: AppLog.logFileURL, containing: failed) > ownBefore)
        #expect(Self.lines(in: person, containing: marker) == 0)
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
              machine: String?? = nil, sent: [SentDay]?? = nil, heldBefore: String?? = nil) -> LeaderboardRecord {
        LeaderboardRecord(username: username, sharing: sharing ?? self.sharing, visible: visible ?? self.visible,
                          lastUpload: lastUpload ?? self.lastUpload, sharesCountry: sharesCountry,
                          globeHintDismissed: globeHintDismissed, link: link, refused: refused ?? self.refused,
                          shownDevices: shownDevices, machine: machine ?? self.machine, addedAsDevice: addedAsDevice,
                          sent: sent ?? self.sent, heldBefore: heldBefore ?? self.heldBefore)
    }
}

extension [SentDay] {
    /// As `LeaderboardRecord` keeps them: by day, then provider.
    func sorted() -> [SentDay] {
        sorted { ($0.day, $0.provider) < ($1.day, $1.provider) }
    }
}
