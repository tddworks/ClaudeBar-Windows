#if os(Linux)
import ClaudeBarShared
import Foundation
import Glibc
import ProbeCore
import Testing

extension ProbeRuns {
    /// The environment import, through a real login shell (design, *Tests*:
    /// the environment, on the runner).
    @Suite
    struct EnvironmentImportRunTests {
        /// The user's `.bashrc`: Ubuntu's from `/etc/skel`, which returns at
        /// once when the shell isn't interactive, then `lines`.
        private func bashrc(_ user: ProbeUser, _ lines: String) throws {
            let skel = (try? String(contentsOfFile: "/etc/skel/.bashrc", encoding: .utf8))
                ?? "case $- in\n    *i*) ;;\n      *) return;;\nesac\n"
            try user.write(".bashrc", skel + "\n" + lines + "\n")
        }

        /// A Codex login and today's session in `~/alt-codex`, and an empty `~/.codex`.
        private func altCodex(_ user: ProbeUser) throws {
            try user.write("alt-codex/auth.json", #"{"tokens":{"account_id":"fixture"}}"#)
            try user.write(Records.codexSession("alt-codex"), Records.codex(0, tokens: 300) + "\n")
            try user.makeFolder(".codex")
        }

        @Test
        func `should read CODEX_HOME from the shell, and skip it when Windows reads it too`() throws {
            let user = try ProbeUser()
            try altCodex(user)
            try bashrc(user, "export CODEX_HOME=$HOME/alt-codex")

            let plain = try user.run(["--logs-only", "--windows-roots", try user.rootsFile()], marker: ProbeUser.runId())

            #expect(plain.status == 0, "\(plain.stderr)")
            let reading = try plain.reading()
            #expect(reading.environmentImport.state == .imported)
            #expect(reading.environmentImport.names.contains("CODEX_HOME"))
            #expect(reading.days.contains { $0.provider == "codex" && $0.day == Records.label(0) })

            let credentials = user.windowsPath("alt-codex"), logs = user.windowsPath("alt-codex/sessions")
            let roots = try user.rootsFile([ProviderRoots(provider: "codex", credentials: [credentials], logs: [logs])])
            let shared = try user.run(["--logs-only", "--windows-roots", roots], marker: ProbeUser.runId())

            let skipped = try shared.reading().skipped.filter { $0.provider == "codex" }
            #expect(skipped.contains { $0.kind == .credentials && $0.reason == .shared && $0.windowsPath == credentials })
            #expect(skipped.contains { $0.kind == .logs && $0.reason == .shared })
            #expect(try shared.reading().days.contains { $0.provider == "codex" } == false)
        }

        @Test
        func `should read the default folder when the shell exports nothing`() throws {
            let user = try ProbeUser()
            try altCodex(user)
            try bashrc(user, "")
            let roots = try user.rootsFile([ProviderRoots(provider: "codex", credentials: [user.windowsPath("alt-codex")], logs: [])])

            let result = try user.run(["--logs-only", "--windows-roots", roots], marker: ProbeUser.runId())

            #expect(result.status == 0, "\(result.stderr)")
            let reading = try result.reading()
            #expect(reading.environmentImport.state == .imported)
            #expect(!reading.days.contains { $0.provider == "codex" })
            #expect(!reading.skipped.contains { $0.provider == "codex" })
        }

        @Test
        func `should give up on a shell that hangs after 3 s, and go on without it`() throws {
            let user = try ProbeUser()
            try altCodex(user)
            try user.write(".bashrc", "sleep 30\nexport CODEX_HOME=$HOME/alt-codex\n")
            let id = ProbeUser.runId()

            let result = try user.run(["--logs-only", "--windows-roots", try user.rootsFile()], marker: id)

            #expect(result.status == 0, "\(result.stderr)")
            let reading = try result.reading()
            #expect(reading.environmentImport.state == .failed)
            #expect(reading.environmentImport.reason == "timed out after 3 s")
            #expect(reading.environmentImport.names.isEmpty)
            #expect(result.seconds < 10)
            #expect(EndRun.processes(carrying: .run(id)).isEmpty)
        }

        @Test
        func `should read only env's own output, whatever the shell files print or start`() throws {
            let user = try ProbeUser()
            try altCodex(user)
            try bashrc(user, """
                export CODEX_HOME=$HOME/alt-codex
                echo CODEX_HOME=/wrong
                env -0
                (for i in $(seq 50); do printf 'CODEX_HOME=/wrong\\0'; sleep 0.05; done) &
                """)
            let id = ProbeUser.runId()

            let result = try user.run(["--logs-only", "--windows-roots", try user.rootsFile()], marker: id)

            #expect(result.status == 0, "\(result.stderr)")
            let reading = try result.reading()
            #expect(reading.environmentImport.state == .imported, "\(reading.environmentImport)")
            #expect(reading.days.contains { $0.provider == "codex" && $0.day == Records.label(0) })
            #expect(EndRun.processes(carrying: .run(id)).isEmpty)
        }

        @Test
        func `should never take PATH from the shell, so a shim on it isn't the CLI found`() throws {
            let user = try ProbeUser()
            try user.write(".codex/" + Records.codexSession("").dropFirst(), Records.codex(0, tokens: 300) + "\n")
            try user.write("fake-drive/npm/codex", "#!/bin/sh\necho windows\n", executable: true)
            try user.write(".local/bin/codex", "#!/bin/sh\necho linux\n", executable: true)
            try bashrc(user, "export PATH=$HOME/fake-drive/npm:$PATH")
            try user.write(".claudebar/providers/pathtool.json", PathProvider.json)

            let result = try user.run(["--logs-only", "--windows-roots", try user.rootsFile()], marker: ProbeUser.runId())

            #expect(result.status == 0, "\(result.stderr)")
            let reading = try result.reading()
            #expect(reading.environmentImport.state == .imported)
            #expect(!reading.environmentImport.names.contains("PATH"))
            #expect(reading.tools.first { $0.id == "codex" }?.cli == user.home.path + "/.local/bin/codex")
        }
    }
}

/// A person's own definition whose setting defaults to `${PATH}`.
private enum PathProvider {
    static let json = """
        {
          "profile": { "id": "pathtool", "name": "Path Tool", "links": { "dashboard": "https://example.com" },
                       "look": { "symbol": "terminal.fill", "color": { "light": [0.2, 0.4, 0.6], "dark": [0.3, 0.5, 0.7] } } },
          "cli": "pathtool",
          "enabledByDefault": true,
          "order": 900,
          "settings": [ { "id": "searchPath", "label": "Search path", "default": "${PATH}" } ],
          "defaultDataSource": "cli",
          "dataSources": [ { "kind": "cli", "label": "CLI", "summary": "Runs pathtool",
                             "fetch": { "command": { "cli": "pathtool", "args": ["usage"], "timeout": 5 } },
                             "mapping": { "script": { "file": "omp-usage.js" } } } ],
          "usageHistory": { "records": { "files": "${MY_TOOL_HOME:-~/.mytool}/usage.jsonl", "format": "jsonLines",
                            "at": "$.timestamp", "tokens": { "input": "$.input" } } }
        }
        """
}
#endif
