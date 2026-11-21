import Foundation
import Testing

/// The hourly `claudebar-upload.exe` says how its run ended in the log, and
/// then ends. The log writes each line on a queue of its own, which ending
/// the process at once would end with that last line still on it.
@Suite
struct UploadOutcomeLineTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cbw-\(UUID().uuidString)", isDirectory: true)

    /// `swift test` builds every product beside the test binary, the uploader too.
    private static var uploader: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("claudebar-upload.exe")
    }

    /// Not joined, so the run logs that it skipped and ends: the same last
    /// step as after an upload, with no server. Five runs, each its own log.
    @Test func `should have the run's last line in the log once the uploader has ended`() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploader = Self.uploader
        try #require(FileManager.default.fileExists(atPath: uploader.path), "no claudebar-upload.exe at \(uploader.path)")
        var lines: [Int] = []
        for run in 0..<5 {
            let local = folder.appendingPathComponent("local-\(run)", isDirectory: true)
            let temp = folder.appendingPathComponent("temp-\(run)", isDirectory: true)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = uploader
            // A `.xctest` argument makes ClaudeBar's log take the run for a
            // test run's: its log goes to a folder of its own under %TEMP%,
            // never the person's. The settings file, under %LOCALAPPDATA%,
            // is a new folder's, with no membership.
            process.arguments = ["UploadOutcomeLineTests.xctest"]
            var environment = ProcessInfo.processInfo.environment
            environment["LOCALAPPDATA"] = local.path
            environment["TMP"] = temp.path
            environment["TEMP"] = temp.path
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)

            let logs = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("ClaudeBar-test-log-") }
            #expect(logs.count == 1)
            let text = logs.first.flatMap { try? Data(contentsOf: $0.appendingPathComponent("ClaudeBar.log")) }
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            lines.append(text.split(separator: "\n").filter { $0.contains("Leaderboard upload skipped: not joined") }.count)
        }

        #expect(lines == [1, 1, 1, 1, 1])
    }
}
