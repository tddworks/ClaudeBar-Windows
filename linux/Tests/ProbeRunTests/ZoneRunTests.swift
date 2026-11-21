#if os(Linux)
import ClaudeBarShared
import DataSources
import Foundation
import Glibc
import ProbeCore
import Providers
import Quotas
import Testing

extension ProbeRuns {
    /// The probe in the zone the app sends (design, *The time zone*, *Kept
    /// days carry no zone*, and *Tests*: the zone and kept days across a zone
    /// change, on the runner). The runner is the PC's Ubuntu: tzdata without
    /// tzdata-legacy, so `Asia/Calcutta` has no file.
    @Suite
    struct ZoneRunTests {
        /// The research's five Claude records, moved by whole days so the last
        /// is two days before today: closed, in the window, in any zone.
        private static let records: [(at: Date, tokens: Int)] = {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let research = [("2026-11-08T14:30:00Z", 1), ("2026-11-08T15:30:00Z", 10), ("2026-11-08T20:00:00Z", 10000),
                            ("2026-11-09T07:30:00Z", 100), ("2026-11-09T08:30:00Z", 1000)]
            let iso = ISO8601DateFormatter()
            let last = iso.date(from: "2026-11-09T08:30:00Z")!
            let target = utc.date(byAdding: .day, value: -2, to: utc.startOfDay(for: Date()))!
            let shift = utc.dateComponents([.day], from: utc.startOfDay(for: last), to: target).day!
            return research.map { (utc.date(byAdding: .day, value: shift, to: iso.date(from: $0.0)!)!, $0.1) }
        }()

        /// The container's own zone, as the probe without `TZ` counts in it.
        private static var ownZone: String { DataSources.timeZone().identifier }

        private func writeRecords(_ user: ProbeUser) throws {
            let lines = Self.records.enumerated().map { Records.claude(at: $1.at, tokens: $1.tokens, id: "z\($0)") }
            try user.write(".claude/projects/p/s.jsonl", lines.joined(separator: "\n") + "\n")
        }

        /// Each record's day as a calendar in `zone` dates it, its tokens (and
        /// its 5 output tokens) summed per day.
        private func expected(in zone: String) -> [String: Int] {
            var days: [String: Int] = [:]
            for record in Self.records {
                days[Records.label(of: record.at, in: TimeZone(identifier: zone)!), default: 0] += record.tokens + 5
            }
            return days
        }

        private func claudeDays(_ reading: ProbeReading) -> [String: Int]? {
            reading.days.map { days in
                Dictionary(days.filter { $0.provider == "claude" }.map { ($0.day, $0.total) }, uniquingKeysWith: +)
            }
        }

        /// A Claude Code that writes the environment it was started with, and exits.
        private func envWritingClaude(_ user: ProbeUser) throws {
            try user.write(".local/bin/claude", "#!/bin/sh\n/usr/bin/env > \(user.home.path)/claude-env\nexit 0\n", executable: true)
        }

        /// A `--logs-only` run; `roots` an existing roots file, else a new one
        /// (whose write gives the whole home back to the user).
        private func logsOnly(_ user: ProbeUser, tz: String?, roots: String? = nil) throws -> ProbeReading {
            let result = try user.run(["--logs-only", "--windows-roots", try roots ?? user.rootsFile()], marker: ProbeUser.runId(),
                                      environment: tz.map { ["TZ=\($0)"] } ?? [])
            #expect(result.status == 0, "\(result.stderr)")
            return try result.reading()
        }

        /// Adds a day the logs don't have to the user's Claude page, as one kept long ago.
        private func plantDay(_ user: ProbeUser) throws {
            let url = user.home.appendingPathComponent(".claudebar/usage-history/claude.json")
            let page = try JSONDecoder().decode(LedgerPage.self, from: Data(contentsOf: url))
            var days = page.days
            days["2020-01-01"] = DailyUsageStat(date: Date(timeIntervalSince1970: 1_577_836_800), totalCost: 0, totalTokens: 1,
                                                workingTime: 0, sessionCount: 1, inputTokens: 1)
            try user.write(".claudebar/usage-history/claude.json",
                           String(decoding: try JSONEncoder().encode(LedgerPage(fingerprint: page.fingerprint, days: days)), as: UTF8.self))
        }

        private func hasPlantedDay(_ user: ProbeUser) -> Bool {
            let url = user.home.appendingPathComponent(".claudebar/usage-history/claude.json")
            guard let data = try? Data(contentsOf: url), let page = try? JSONDecoder().decode(LedgerPage.self, from: data) else { return false }
            return page.days["2020-01-01"] != nil
        }

        @Test
        func `should be a runner without tzdata-legacy, as the PC's Ubuntu`() {
            #expect(FileManager.default.fileExists(atPath: "/usr/share/zoneinfo/Asia/Seoul"))
            #expect(!FileManager.default.fileExists(atPath: "/usr/share/zoneinfo/Asia/Calcutta"))
        }

        /// `Etc/` names too: what the app sends for UTC, and for a whole-hour
        /// offset when daylight saving's adjustment is off (`WslZone`); the
        /// answer must name the zone as sent, or Windows keeps nothing.
        @Test(arguments: ["Asia/Seoul", "America/Los_Angeles", "Etc/UTC", "Etc/GMT-9", "Etc/GMT+5"])
        func `should date each record in the zone the app sends`(zone: String) throws {
            let user = try ProbeUser()
            try writeRecords(user)

            let reading = try logsOnly(user, tz: zone)

            #expect(reading.timeZone == zone)
            #expect(claudeDays(reading) == expected(in: zone))
            #expect(!reading.diagnostics.contains { $0.hasPrefix("no time zone") }, "\(reading.diagnostics)")
        }

        @Test
        func `should count Seoul's days and Los Angeles' apart, whatever the runner's zone`() {
            // On the research's dates: 11-08: 1, 11-09: 11110 and 11-08: 10111, 11-09: 1000 (+5 output tokens a record).
            #expect(expected(in: "Asia/Seoul") != expected(in: "America/Los_Angeles"))
        }

        @Test(arguments: [
            ("Asia/Calcutta", "no time zone data for Asia/Calcutta (/usr/share/zoneinfo/Asia/Calcutta)"),
            ("Nowhere/Zone", "no time zone data for Nowhere/Zone (/usr/share/zoneinfo/Nowhere/Zone)"),
            ("GMT+0900", "no time zone data for GMT+0900 (/usr/share/zoneinfo/GMT+0900)"),
        ])
        func `should answer no days for a zone the distro can't count in, in its own zone`(zone: String, diagnostic: String) throws {
            let user = try ProbeUser()
            try writeRecords(user)

            let reading = try logsOnly(user, tz: zone)

            #expect(reading.days == nil)
            #expect(reading.diagnostics.contains(diagnostic), "\(reading.diagnostics)")
            #expect(reading.timeZone == Self.ownZone)
            #expect(reading.tools.contains { $0.id == "claude" && $0.logs }, "\(reading.tools)")
        }

        @Test
        func `should start a CLI without a TZ it refused`() throws {
            let user = try ProbeUser()
            try envWritingClaude(user)
            try writeRecords(user)

            let result = try user.run(["--json", "--windows-roots", try user.rootsFile(), "--deadline", "15"],
                                      marker: ProbeUser.runId(), environment: ["TZ=Asia/Calcutta"])

            #expect(result.status == 0, "\(result.stderr)")
            #expect(try result.reading().days == nil)
            let env = try #require(user.read("claude-env"), "the fixture CLI never ran")
            #expect(!env.split(separator: "\n").contains { $0.hasPrefix("TZ=") }, "\(env)")
        }

        @Test
        func `should start a CLI with the TZ it counts in`() throws {
            let user = try ProbeUser()
            try envWritingClaude(user)
            try writeRecords(user)

            let result = try user.run(["--json", "--windows-roots", try user.rootsFile(), "--deadline", "15"],
                                      marker: ProbeUser.runId(), environment: ["TZ=America/Los_Angeles"])

            #expect(result.status == 0, "\(result.stderr)")
            let env = try #require(user.read("claude-env"), "the fixture CLI never ran")
            #expect(env.split(separator: "\n").contains("TZ=America/Los_Angeles"), "\(env)")
        }

        @Test
        func `should start the kept days over when the zone changes, and only then`() throws {
            let user = try ProbeUser()
            try writeRecords(user)

            // A phase 1 probe's run: no TZ, the container's own zone; the closed days are kept.
            let first = try logsOnly(user, tz: nil)
            #expect(first.timeZone == Self.ownZone)
            #expect(claudeDays(first) == expected(in: Self.ownZone))
            try plantDay(user)

            // A PC updated straight to phase 2: Windows' zone, another.
            let second = try logsOnly(user, tz: "America/Los_Angeles")
            #expect(claudeDays(second) == expected(in: "America/Los_Angeles"))
            #expect(second.diagnostics.contains("kept days started over: counting in America/Los_Angeles now"), "\(second.diagnostics)")
            #expect(user.read(".local/share/ClaudeBar/wsl-zone") == "America/Los_Angeles")
            #expect(!hasPlantedDay(user), "the page the first run kept is still there")

            // The same zone again: nothing removed.
            try plantDay(user)
            let third = try logsOnly(user, tz: "America/Los_Angeles")
            #expect(claudeDays(third) == expected(in: "America/Los_Angeles"))
            #expect(!third.diagnostics.contains { $0.hasPrefix("kept days started over") }, "\(third.diagnostics)")
            #expect(hasPlantedDay(user))

            // Refused: no days, and the kept days follow the zone it counted in, its own.
            let fourth = try logsOnly(user, tz: "Asia/Calcutta")
            #expect(fourth.days == nil)
            #expect(user.read(".local/share/ClaudeBar/wsl-zone") == Self.ownZone)
        }

        @Test(.enabled(if: getuid() == 0, "makes a page the user can't remove"))
        func `should answer no days when it can't start the kept days over`() throws {
            let user = try ProbeUser()
            try writeRecords(user)
            let roots = try user.rootsFile()
            _ = try logsOnly(user, tz: "Asia/Seoul", roots: roots)
            // The ledger's folder, root's and read-only to the user: its pages can't be removed.
            let ledger = user.home.appendingPathComponent(".claudebar/usage-history").path
            try ProbeUser.command(["chown", "root:root", ledger])
            try ProbeUser.command(["chmod", "0755", ledger])

            let reading = try logsOnly(user, tz: "America/Los_Angeles", roots: roots)

            #expect(reading.days == nil)
            let page = ledger + "/claude.json"
            #expect(reading.diagnostics.contains("couldn't start the kept days over for America/Los_Angeles: \(page): Permission denied"),
                    "\(reading.diagnostics)")
            #expect(reading.timeZone == "America/Los_Angeles")
            #expect(user.read(".local/share/ClaudeBar/wsl-zone") == "Asia/Seoul")
        }

        @Test
        func `should never take TZ from the shell`() throws {
            let user = try ProbeUser()
            try writeRecords(user)
            let skel = (try? String(contentsOfFile: "/etc/skel/.bashrc", encoding: .utf8))
                ?? "case $- in\n    *i*) ;;\n      *) return;;\nesac\n"
            try user.write(".bashrc", skel + "\nexport TZ=Asia/Tokyo\n")
            try user.write(".claudebar/providers/tztool.json", TzProvider.json)

            let reading = try logsOnly(user, tz: "America/Los_Angeles")

            #expect(reading.environmentImport.state == .imported, "\(reading.environmentImport)")
            #expect(!reading.environmentImport.names.contains("TZ"))
            #expect(reading.timeZone == "America/Los_Angeles")
            #expect(claudeDays(reading) == expected(in: "America/Los_Angeles"))
        }

        @Test
        func `should answer the log roots its days were read from, in Windows form`() throws {
            let user = try ProbeUser()
            try writeRecords(user)

            let own = try user.run(["--logs-only", "--windows-roots", try user.rootsFile(distro: "Ubuntu-26.04")],
                                   marker: ProbeUser.runId())

            #expect(own.status == 0, "\(own.stderr)")
            #expect(try own.reading().logRoots.filter { $0.provider == "claude" }
                    == [ProbeReading.LogRoot(provider: "claude", windowsPath: user.windowsPath(".claude/projects", distro: "Ubuntu-26.04"))])

            let roots = try user.rootsFile(distro: "Ubuntu-26.04", [
                ProviderRoots(provider: "claude", credentials: [], logs: [user.windowsPath(".claude", distro: "Ubuntu-26.04")]),
            ])
            let shared = try user.run(["--logs-only", "--windows-roots", roots], marker: ProbeUser.runId())

            #expect(shared.status == 0, "\(shared.stderr)")
            let reading = try shared.reading()
            #expect(!reading.logRoots.contains { $0.provider == "claude" }, "\(reading.logRoots)")
            #expect(reading.days?.contains { $0.provider == "claude" } == false)
        }
    }
}

/// A person's own definition whose setting defaults to `${TZ}`.
private enum TzProvider {
    static let json = """
        {
          "profile": { "id": "tztool", "name": "TZ Tool", "links": { "dashboard": "https://example.com" },
                       "look": { "symbol": "terminal.fill", "color": { "light": [0.2, 0.4, 0.6], "dark": [0.3, 0.5, 0.7] } } },
          "cli": "tztool",
          "enabledByDefault": true,
          "order": 900,
          "settings": [ { "id": "zone", "label": "Zone", "default": "${TZ}" } ],
          "defaultDataSource": "cli",
          "dataSources": [ { "kind": "cli", "label": "CLI", "summary": "Runs tztool",
                             "fetch": { "command": { "cli": "tztool", "args": ["usage"], "timeout": 5 } },
                             "mapping": { "script": { "file": "omp-usage.js" } } } ],
          "usageHistory": { "records": { "files": "${MY_TOOL_HOME:-~/.mytool}/usage.jsonl", "format": "jsonLines",
                            "at": "$.timestamp", "tokens": { "input": "$.input" } } }
        }
        """
}
#endif
