import Diagnostics
import Foundation
import Leaderboard
import WinSDK

/// The membership's record and the on/off switch, in a JSON file of the
/// person's on this PC: `%LOCALAPPDATA%\ClaudeBar\settings.json`. The private
/// key isn't here; Credential Manager keeps it.
///
/// The app and the hourly uploader are separate processes that both read and
/// write it, so every read and write holds one named mutex. That alone would
/// still lose a change: each membership holds the record it read, and saves it
/// whole, so an upload that started before the person stopped sharing a
/// provider would share it again when it records itself. So an instance is
/// one membership's view (`view()`): it remembers what that membership read,
/// and a save writes only the fields it changed since, keeping the rest as
/// the file has them. The file also counts memberships (`generation`): a
/// membership that has left, or been replaced by a new join, since its view
/// read saves nothing, so it can't bring itself back or overwrite the new one.
public final class SettingsFile: LeaderboardSettingsRepository, @unchecked Sendable {
    public let url: URL
    public let lockName: String
    /// What this view's membership last read or saved, and in which membership.
    private var base: (generation: Int, record: LeaderboardRecord?)?

    public init(url: URL = SettingsFile.defaultURL, lockName: String = #"Local\ClaudeBar.settings"#) {
        self.url = url
        self.lockName = lockName
    }

    /// A view of the same file for another membership, remembering nothing yet.
    public func view() -> SettingsFile {
        SettingsFile(url: url, lockName: lockName)
    }

    public static var defaultURL: URL {
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        return local.appendingPathComponent("ClaudeBar", isDirectory: true).appendingPathComponent("settings.json")
    }

    public func leaderboardRecord() -> LeaderboardRecord? {
        locked {
            let contents = read()
            let record = contents.leaderboard?.record
            base = (contents.generation ?? 0, record)
            return record
        }
    }

    public func saveLeaderboardRecord(_ record: LeaderboardRecord?) {
        locked {
            var contents = read()
            let generation = contents.generation ?? 0
            let theirs = contents.leaderboard?.record
            let base = self.base ?? (generation, theirs)
            guard base.generation == generation else {
                AppLog.ui.info("Leaderboard settings: a membership that has since left or been replaced saved nothing")
                return
            }
            switch (record, theirs) {
            case (nil, nil):
                break
            case (nil, _?):
                // This membership ends: leaving, or forgotten by the server.
                contents.leaderboard = nil
                contents.generation = generation + 1
            case (let mine?, nil):
                // A membership begins: joining.
                contents.leaderboard = StoredRecord(mine)
                contents.generation = generation + 1
            case (let mine?, let theirs?):
                contents.leaderboard = StoredRecord(Self.merge(mine, since: base.record ?? theirs, onto: theirs))
            }
            if record != nil || theirs != nil { write(contents) }
            self.base = (contents.generation ?? 0, record)
        }
    }

    /// Each field as this membership has it where it changed it since `base`,
    /// else as the file has it.
    static func merge(_ mine: LeaderboardRecord, since base: LeaderboardRecord, onto theirs: LeaderboardRecord) -> LeaderboardRecord {
        func pick<Value: Equatable>(_ field: KeyPath<LeaderboardRecord, Value>) -> Value {
            mine[keyPath: field] != base[keyPath: field] ? mine[keyPath: field] : theirs[keyPath: field]
        }
        return LeaderboardRecord(username: pick(\.username), sharing: pick(\.sharing), visible: pick(\.visible),
                                 lastUpload: pick(\.lastUpload), sharesCountry: pick(\.sharesCountry),
                                 globeHintDismissed: pick(\.globeHintDismissed), link: pick(\.link),
                                 refused: pick(\.refused), shownDevices: pick(\.shownDevices))
    }

    public func isLeaderboardOn() -> Bool {
        locked { read().leaderboardOn ?? true }
    }

    public func setLeaderboardOn(_ on: Bool) {
        locked {
            var contents = read()
            contents.leaderboardOn = on
            write(contents)
        }
    }

    // MARK: - The file

    private struct Contents: Codable {
        var leaderboard: StoredRecord?
        var leaderboardOn: Bool?
        /// Counts memberships: each join and each end of one adds one.
        var generation: Int?
    }

    private struct StoredRecord: Codable {
        var username: String
        var sharing: [String]
        var visible: Bool
        var lastUpload: Date?
        var sharesCountry: Bool
        var globeHintDismissed: Bool
        var link: ProfileLink?
        var refused: [RefusedDay]
        var shownDevices: [String]

        init(_ record: LeaderboardRecord) {
            username = record.username
            sharing = record.sharing
            visible = record.visible
            lastUpload = record.lastUpload
            sharesCountry = record.sharesCountry
            globeHintDismissed = record.globeHintDismissed
            link = record.link
            refused = record.refused
            shownDevices = record.shownDevices
        }

        var record: LeaderboardRecord {
            LeaderboardRecord(username: username, sharing: sharing, visible: visible, lastUpload: lastUpload,
                              sharesCountry: sharesCountry, globeHintDismissed: globeHintDismissed, link: link,
                              refused: refused, shownDevices: shownDevices)
        }
    }

    /// The file as it is; a missing or damaged one holds nothing.
    private func read() -> Contents {
        guard let data = FileManager.default.contents(atPath: url.path) else { return Contents() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(Contents.self, from: data)) ?? Contents()
    }

    private func write(_ contents: Contents) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(contents).write(to: url, options: .atomic)
        } catch {
            AppLog.ui.error("Leaderboard settings could not be saved: \(error.localizedDescription)")
        }
    }

    /// Runs `body` holding the named mutex every process of this person's
    /// shares. A process that died holding it leaves it abandoned, which still
    /// hands it over.
    private func locked<T>(_ body: () -> T) -> T {
        let mutex = lockName.withCString(encodedAs: UTF16.self) { CreateMutexW(nil, false, $0) }
        guard let mutex else { return body() }
        defer { CloseHandle(mutex) }
        let wait = WaitForSingleObject(mutex, 10_000)
        // WAIT_OBJECT_0, or WAIT_ABANDONED (0x80): a process that died holding it hands it over.
        guard wait == WAIT_OBJECT_0 || wait == 0x80 else { return body() }
        defer { ReleaseMutex(mutex) }
        return body()
    }
}
