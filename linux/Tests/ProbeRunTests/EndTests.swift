#if os(Linux)
import Foundation
import Glibc
import ProbeCore
import Testing

extension ProbeRuns {
    /// `--end` (design, *Tests*): checked by PID, since "no marked process
    /// left" would pass with a probe that lost its marker.
    @Suite
    struct EndTests {
        /// A Claude Code that starts a grandchild in a session of its own, so
        /// it's reparented when its parent ends, writes both PIDs, and never answers.
        private func claudeWithGrandchild(_ user: ProbeUser) throws {
            let home = user.home.path
            try user.write(".local/bin/claude", """
                #!/bin/sh
                setsid sleep 600 >/dev/null 2>&1 &
                echo $! > \(home)/grandchild-$CLAUDEBAR_WSL_RUN.pid
                echo $$ > \(home)/claude-$CLAUDEBAR_WSL_RUN.pid
                exec sleep 600
                """, executable: true)
        }

        private func pid(_ user: ProbeUser, _ file: String) throws -> pid_t {
            try #require(user.waitFor(file, seconds: 30), "\(file) never written")
            usleep(100_000)
            return try #require(user.read(file).flatMap { pid_t($0) })
        }

        @Test
        func `should end a stopped probe, its CLI and the CLI's reparented grandchild`() throws {
            let user = try ProbeUser()
            try claudeWithGrandchild(user)
            let id = ProbeUser.runId()
            let run = try user.start(["--json", "--windows-roots", try user.rootsFile(), "--deadline", "60"], marker: id)
            let cli = try pid(user, "claude-\(id).pid")
            let grandchild = try pid(user, "grandchild-\(id).pid")
            kill(run.pid, SIGSTOP)

            let end = try user.run(["--end", id], marker: nil)
            let probe = run.finish()

            #expect(end.status == 0, "\(end.stderr)")
            #expect(probe.status != 0)
            #expect(probe.stdout.isEmpty)
            #expect(ProbeUser.isGone(run.pid))
            #expect(ProbeUser.isGone(cli))
            #expect(ProbeUser.isGone(grandchild))
        }

        @Test
        func `should end every run with end all`() throws {
            let user = try ProbeUser()
            try claudeWithGrandchild(user)
            let ids = [ProbeUser.runId(), ProbeUser.runId()]
            let runs = try ids.map { try user.start(["--json", "--windows-roots", try user.rootsFile(), "--deadline", "60"], marker: $0) }
            let clis = try ids.map { try pid(user, "claude-\($0).pid") }

            let end = try user.run(["--end", "all"], marker: nil)
            let probes = runs.map { $0.finish() }

            #expect(end.status == 0, "\(end.stderr)")
            #expect(probes.allSatisfy { $0.stdout.isEmpty })
            for pid in runs.map(\.pid) + clis { #expect(ProbeUser.isGone(pid), "\(pid)") }
        }

        @Test
        func `should end nothing of another run`() throws {
            let user = try ProbeUser()
            try claudeWithGrandchild(user)
            let id = ProbeUser.runId()
            let run = try user.start(["--json", "--windows-roots", try user.rootsFile(), "--deadline", "60"], marker: id)
            let cli = try pid(user, "claude-\(id).pid")

            let end = try user.run(["--end", ProbeUser.runId()], marker: nil)

            #expect(end.status == 0)
            #expect(kill(run.pid, 0) == 0)
            #expect(kill(cli, 0) == 0)
            _ = try user.run(["--end", id], marker: nil)
            _ = run.finish()
        }
    }
}
#endif
