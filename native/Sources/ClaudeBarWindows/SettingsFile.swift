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
    /// Saves that didn't reach the file, shared by a file and all its views:
    /// ClaudeBar's package saves without throwing, so whoever acts for the
    /// person asks here afterwards (`takeFailure()`) and says so.
    private let failures: Failures

    public convenience init(url: URL = SettingsFile.defaultURL, lockName: String = #"Local\ClaudeBar.settings"#) {
        self.init(url: url, lockName: lockName, failures: Failures())
    }

    private init(url: URL, lockName: String, failures: Failures) {
        self.url = url
        self.lockName = lockName
        self.failures = failures
    }

    /// A view of the same file for another membership, remembering nothing yet.
    public func view() -> SettingsFile {
        SettingsFile(url: url, lockName: lockName, failures: failures)
    }

    /// Why the last save since the previous call didn't reach the file, if one didn't.
    public func takeFailure() -> String? {
        failures.take()
    }

    public static var defaultURL: URL {
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        return local.appendingPathComponent("ClaudeBar", isDirectory: true).appendingPathComponent("settings.json")
    }

    public func leaderboardRecord() -> LeaderboardRecord? {
        // Without the lock, the read still sees a whole file (writes replace it atomically).
        let read = locked(orElse: { self.read() }) { self.read() }
        let record = read.leaderboard?.record
        base = (read.generation ?? 0, record)
        return record
    }

    public func saveLeaderboardRecord(_ record: LeaderboardRecord?) {
        locked(orElse: { failures.record("another ClaudeBar kept the settings file busy") }) {
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
                return
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
            // A save that failed leaves `base` as it was, so the next one still writes this change.
            guard write(contents) else { return }
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
                                 refused: pick(\.refused), shownDevices: pick(\.shownDevices),
                                 machine: pick(\.machine), addedAsDevice: pick(\.addedAsDevice))
    }

    public func isLeaderboardOn() -> Bool {
        locked(orElse: { self.read() }) { self.read() }.leaderboardOn ?? true
    }

    public func setLeaderboardOn(_ on: Bool) {
        locked(orElse: { failures.record("another ClaudeBar kept the settings file busy") }) {
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
        /// Optional, as a file written before they were kept has neither.
        var machine: String?
        var addedAsDevice: Bool?

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
            machine = record.machine
            addedAsDevice = record.addedAsDevice
        }

        var record: LeaderboardRecord {
            LeaderboardRecord(username: username, sharing: sharing, visible: visible, lastUpload: lastUpload,
                              sharesCountry: sharesCountry, globeHintDismissed: globeHintDismissed, link: link,
                              refused: refused, shownDevices: shownDevices, machine: machine, addedAsDevice: addedAsDevice ?? false)
        }
    }

    /// The file as it is; a missing or damaged one holds nothing.
    private func read() -> Contents {
        guard let data = FileManager.default.contents(atPath: url.path) else { return Contents() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(Contents.self, from: data)) ?? Contents()
    }

    /// Writes the file whole, atomically; a failure is logged and kept for `takeFailure()`.
    @discardableResult
    private func write(_ contents: Contents) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.replace(url, with: encoder.encode(contents))
            return true
        } catch {
            AppLog.ui.error("Leaderboard settings could not be saved: \(error.localizedDescription)")
            failures.record(error.localizedDescription)
            return false
        }
    }

    /// Puts `data` in place of the file at `url` in one step: it's written
    /// whole to a new file beside it, which is then renamed over it, so a
    /// reader finds the old contents or the new, never part of either.
    ///
    /// Not `Data.write(to:options: .atomic)`: on Windows, Foundation opens its
    /// new file with a C runtime descriptor that child processes inherit, and
    /// lets no one else delete it. A program this process started while that
    /// was open (`schtasks.exe` from the app, a `Foundation.Process`) kept a
    /// copy as long as it ran, the rename failed with a sharing violation
    /// (Win32 error 32), and the save was lost, its new file left behind.
    /// Here one handle, which no child inherits, writes the new file and
    /// renames it; until it closes, others may only read the file. A program
    /// holding the file itself open for a moment without letting it be
    /// replaced (error 32 or 5) is waited for, up to a second.
    private static func replace(_ url: URL, with data: Data) throws {
        let fresh = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        // No security attributes: the handle isn't inherited.
        let opened = fresh.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE) | DWORD(DELETE), DWORD(FILE_SHARE_READ), nil, DWORD(CREATE_NEW),
                        DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle = opened, handle != INVALID_HANDLE_VALUE else { throw SaveFailure("making a new file beside it") }
        var renamed = false
        defer {
            CloseHandle(handle)
            if !renamed { _ = fresh.path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) } }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                var written: DWORD = 0
                guard WriteFile(handle, bytes.baseAddress! + offset, DWORD(bytes.count - offset), &written, nil) else {
                    throw SaveFailure("writing the new file")
                }
                offset += Int(written)
            }
        }
        guard FlushFileBuffers(handle) else { throw SaveFailure("writing the new file") }
        var waited = 0
        while !rename(handle, to: url) {
            let error = GetLastError()
            guard error == DWORD(ERROR_SHARING_VIOLATION) || error == DWORD(ERROR_ACCESS_DENIED), waited < 1000 else {
                throw SaveFailure("putting the new file in its place", error)
            }
            Sleep(50)
            waited += 50
        }
        renamed = true
    }

    /// Renames the open file to `url`, replacing what's there even while
    /// others have it open, as long as they let it be deleted (POSIX semantics).
    private static func rename(_ handle: HANDLE, to url: URL) -> Bool {
        let target = Array(url.path.utf16)
        let nameOffset = MemoryLayout<FILE_RENAME_INFO>.offset(of: \FILE_RENAME_INFO.FileName)!
        // As Foundation sizes it: the structure, then the name and its terminator.
        let size = MemoryLayout<FILE_RENAME_INFO>.size + (target.count + 1) * MemoryLayout<WCHAR>.size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<FILE_RENAME_INFO>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let info = buffer.bindMemory(to: FILE_RENAME_INFO.self, capacity: 1)
        info.pointee.Flags = DWORD(FILE_RENAME_FLAG_POSIX_SEMANTICS | FILE_RENAME_FLAG_REPLACE_IF_EXISTS)
        info.pointee.FileNameLength = DWORD(target.count * MemoryLayout<WCHAR>.size)
        target.withUnsafeBytes { (buffer + nameOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return SetFileInformationByHandle(handle, FileRenameInfoEx, buffer, DWORD(size))
    }

    /// A save that didn't reach the file: the step and its Win32 error.
    private struct SaveFailure: LocalizedError {
        let step: String
        let code: DWORD

        init(_ step: String, _ code: DWORD = GetLastError()) {
            self.step = step
            self.code = code
        }

        var errorDescription: String? { "Windows error \(code) \(step)" }
    }

    /// Runs `body` holding the named mutex every process of this person's
    /// shares; a process that died holding it leaves it abandoned, which still
    /// hands it over. Without the mutex (it can't be made, or another process
    /// holds it 10 s) `body` doesn't run, `fallback` does: a read reads anyway,
    /// a save doesn't save, since merging needs the file not to change under it.
    private func locked<T>(orElse fallback: () -> T, _ body: () -> T) -> T {
        let mutex = lockName.withCString(encodedAs: UTF16.self) { CreateMutexW(nil, false, $0) }
        guard let mutex else {
            AppLog.ui.error("Leaderboard settings: the lock couldn't be made (error \(GetLastError()))")
            return fallback()
        }
        defer { CloseHandle(mutex) }
        let wait = WaitForSingleObject(mutex, 10_000)
        // WAIT_OBJECT_0, or WAIT_ABANDONED (0x80): a process that died holding it hands it over.
        guard wait == WAIT_OBJECT_0 || wait == 0x80 else {
            AppLog.ui.error("Leaderboard settings: the lock wasn't free in 10 s (wait \(wait))")
            return fallback()
        }
        defer { ReleaseMutex(mutex) }
        return body()
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var last: String?

        func record(_ reason: String) {
            lock.lock()
            defer { lock.unlock() }
            last = reason
        }

        func take() -> String? {
            lock.lock()
            defer { lock.unlock() }
            defer { last = nil }
            return last
        }
    }
}
