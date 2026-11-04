#if os(Linux)
import ClaudeBarShared
import Foundation
import Glibc
import ProbeCore
import Testing

/// The runner tests (design, *Tests*: the probe, on the Linux runner). Each
/// makes Linux users and starts the built probe as them; `--end all` ends
/// any run of its user, so they run one at a time.
@Suite(.serialized, .enabled(if: ProbeUser.isRoot, "makes a Linux user, so it runs as root"))
struct ProbeRuns {}

extension ProbeRuns {
    @Suite
    struct ProbeRunTests {
        /// A Claude Code that never answers, and says when it ran.
        private func neverAnsweringClaude(_ user: ProbeUser) throws {
            try user.write(".local/bin/claude", """
                #!/bin/sh
                touch \(user.home.path)/claude-ran
                echo $$ > \(user.home.path)/claude-$CLAUDEBAR_WSL_RUN.pid
                exec sleep 600
                """, executable: true)
        }

        /// Two days of Claude logs: yesterday's and today's.
        private func twoClaudeDays(_ user: ProbeUser) throws {
            try user.write(".claude/projects/p/s.jsonl", [
                Records.claude(1, tokens: 100, id: "a"), Records.claude(0, tokens: 200, id: "b"),
            ].joined(separator: "\n") + "\n")
        }

        @Test
        func `should answer one ProbeReading of this version, with the HUD`() throws {
            let user = try ProbeUser()

            let result = try user.run(["--json", "--windows-roots", try user.rootsFile(), "--deadline", "30"], marker: ProbeUser.runId())

            #expect(result.status == 0, "\(result.stderr)")
            let reading = try result.reading()
            #expect(reading.version == ClientVersion.version)
            #expect(reading.hud != nil)
            #expect(!reading.timeZone.isEmpty)
            // Nothing is set up for a new user: no tool, and not Antigravity, which Linux can't read at all.
            #expect(reading.tools.isEmpty, "\(reading.tools)")
        }

        @Test
        func `should refuse to run without the marker, and print nothing`() throws {
            let user = try ProbeUser()

            let result = try user.run(["--json", "--windows-roots", try user.rootsFile()], marker: nil)

            #expect(result.status == 3)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("CLAUDEBAR_WSL_RUN"))
        }

        @Test
        func `should refuse bad arguments with exit 1 and the reason`() throws {
            let user = try ProbeUser()

            let result = try user.run(["--json"], marker: ProbeUser.runId())

            #expect(result.status == 1)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr == "claudebar-probe: --json needs --windows-roots <file>\n")
        }

        @Test
        func `should answer at the deadline with whole days, and leave nothing running`() throws {
            let user = try ProbeUser()
            try neverAnsweringClaude(user)
            try twoClaudeDays(user)
            let id = ProbeUser.runId()

            let result = try user.run(["--json", "--windows-roots", try user.rootsFile(), "--deadline", "5"], marker: id)

            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.seconds < 15)
            let reading = try result.reading()
            #expect(reading.timedOut)
            #expect(user.exists("claude-ran"))
            #expect(reading.hud?.problems.contains { $0.id == "claude" && $0.kind == "reading" } == true)
            #expect(reading.days.filter { $0.provider == "claude" }.map(\.day) == [Records.label(1), Records.label(0)])
            #expect(reading.tools.contains { $0.id == "claude" && $0.cli == user.home.path + "/.local/bin/claude" && $0.logs })
            #expect(EndRun.processes(carrying: .run(id)).isEmpty)
            if let pid = user.read("claude-\(id).pid").flatMap({ pid_t($0) }) { #expect(ProbeUser.isGone(pid)) }
        }

        @Test
        func `should read only the days with logs-only, and run no CLI`() throws {
            let user = try ProbeUser()
            try neverAnsweringClaude(user)
            try twoClaudeDays(user)
            let roots = try user.rootsFile()
            let full = try user.run(["--json", "--windows-roots", roots, "--deadline", "5"], marker: ProbeUser.runId())
            try FileManager.default.removeItem(at: user.home.appendingPathComponent("claude-ran"))

            let result = try user.run(["--logs-only", "--windows-roots", roots], marker: ProbeUser.runId())

            #expect(result.status == 0, "\(result.stderr)")
            let reading = try result.reading()
            #expect(reading.hud == nil)
            #expect(!reading.timedOut)
            #expect(reading.days == (try full.reading()).days)
            #expect(!reading.days.isEmpty)
            #expect(!user.exists("claude-ran"))
        }

        @Test
        func `should leave Claude to Windows when the roots file names the folder it reads`() throws {
            let user = try ProbeUser()
            try user.makeFolder(".claude")
            let shared = user.windowsPath(".claude")
            let roots = try user.rootsFile(distro: "Test", [ProviderRoots(provider: "claude", credentials: [shared], logs: [])])

            let result = try user.run(["--json", "--windows-roots", roots, "--deadline", "30"], marker: ProbeUser.runId())

            #expect(result.status == 0, "\(result.stderr)")
            let reading = try result.reading()
            #expect(reading.skipped.contains(ProbeReading.Skip(provider: "claude", kind: .credentials, windowsPath: shared, reason: .shared)))
            #expect(reading.hud?.looks.contains { $0.id == "claude" } == false)
            #expect(reading.hud?.problems.contains { $0.id == "claude" } == false)
        }

        @Test
        func `should read a CLI that takes longer than its timeout to start, as one read from a cold disk does`() throws {
            // WSL takes an idle distro's page cache back, so at the HUD's cadence
            // Claude's and Codex's CLIs start from the disk, past their timeouts
            // (tddworks/ClaudeBar#685). This one answers after 4 s; its definition gives it 2.
            let user = try ProbeUser()
            try user.write(".claudebar/providers/slowtool.json", SlowTool.json)
            try user.write(".local/bin/slowtool", "#!/bin/sh\nsleep 4\necho '{\"used\":30}'\n", executable: true)

            let result = try user.run(["--json", "--windows-roots", try user.rootsFile(), "--deadline", "30"], marker: ProbeUser.runId())

            #expect(result.status == 0, "\(result.stderr)")
            let reading = try result.reading()
            #expect(reading.hud?.problems.first { $0.id == "slowtool" } == nil)
            #expect(reading.hud?.looks.contains { $0.id == "slowtool" } == true)
        }

        @Test
        func `should fail on a roots file it can't read`() throws {
            let user = try ProbeUser()

            let result = try user.run(["--json", "--windows-roots", user.home.path + "/missing.json"], marker: ProbeUser.runId())

            #expect(result.status == 1)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.hasPrefix("claudebar-probe: couldn't read the Windows roots file"))
        }
    }
}

/// A person's own definition whose CLI gets 2 s.
private enum SlowTool {
    static let json = """
        {
          "profile": { "id": "slowtool", "name": "Slow Tool", "links": { "dashboard": "https://example.com" },
                       "look": { "symbol": "terminal.fill", "color": { "light": [0.2, 0.4, 0.6], "dark": [0.3, 0.5, 0.7] } } },
          "cli": "slowtool",
          "enabledByDefault": true,
          "order": 900,
          "defaultDataSource": "cli",
          "dataSources": [ { "kind": "cli", "label": "CLI", "summary": "Runs slowtool",
                             "fetch": { "command": { "cli": "slowtool", "args": ["usage"], "timeout": 2 } },
                             "mapping": { "json": { "quotas": [ { "kind": "weekly", "usedPercent": "used" } ] } } } ]
        }
        """
}
#endif
