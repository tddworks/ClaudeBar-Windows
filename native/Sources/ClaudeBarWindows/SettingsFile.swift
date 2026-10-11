import Diagnostics
import Foundation
import Leaderboard
import WinSDK

/// The membership's record and the on/off switch, in a JSON file of the
/// person's on this PC: `%LOCALAPPDATA%\ClaudeBar\settings.json`. The private
/// key isn't here; Credential Manager keeps it.
///
/// The app and the hourly uploader are separate processes that both read and
/// write it, so every read and write holds one named mutex, and a write
/// replaces the file whole.
public final class SettingsFile: LeaderboardSettingsRepository, @unchecked Sendable {
    public let url: URL
    private let lockName: String

    public init(url: URL = SettingsFile.defaultURL, lockName: String = #"Local\ClaudeBar.settings"#) {
        self.url = url
        self.lockName = lockName
    }

    public static var defaultURL: URL {
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        return local.appendingPathComponent("ClaudeBar", isDirectory: true).appendingPathComponent("settings.json")
    }

    public func leaderboardRecord() -> LeaderboardRecord? {
        locked { read().leaderboard?.record }
    }

    public func saveLeaderboardRecord(_ record: LeaderboardRecord?) {
        locked {
            var contents = read()
            contents.leaderboard = record.map(StoredRecord.init)
            write(contents)
        }
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
