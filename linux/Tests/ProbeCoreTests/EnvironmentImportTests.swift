import Foundation
import Providers
import Testing
@testable import ProbeCore

/// The variables the definitions name, read from the person's login shell
/// (design, *The environment*): which names, the command, the file it writes.
@Suite
struct EnvironmentImportTests {
    @Test
    func `should collect every variable a definition names, from the bundled definitions`() {
        let names = EnvironmentImport.names(usedBy: Array(ProviderFactory.builtInDefinitions.values))

        #expect(Set(["CLAUDE_CONFIG_DIR", "CODEX_HOME", "KIMI_SHARE_DIR", "PI_CODING_AGENT_DIR", "XDG_DATA_HOME"]).isSubset(of: Set(names)))
        #expect(names == names.sorted())
    }

    @Test
    func `should collect a variable the person's own definition names`() throws {
        let custom = try ProviderDefinition.parse(fixtureData("custom-provider.json"), origin: .custom)

        #expect(EnvironmentImport.names(usedBy: [custom]).contains("MY_TOOL_HOME"))
    }

    @Test
    func `should never import PATH, even when a definition names it`() throws {
        let custom = try ProviderDefinition.parse(fixtureData("path-provider.json"), origin: .custom)

        #expect(EnvironmentImport.names(usedBy: [custom]) == ["MY_TOOL_HOME"])
    }

    @Test
    func `should read only the names asked for, values with a space or a newline whole`() {
        let file = Data("PATH=/usr/bin\0CODEX_HOME=/home/me/alt codex\0MULTI=a\nb\0EMPTY=\0@@CLAUDEBAR_ENV_END@@".utf8)

        #expect(EnvironmentImport.parse(file, names: ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "MULTI", "EMPTY"])
                == .values(["CODEX_HOME": "/home/me/alt codex", "MULTI": "a\nb"]))
    }

    @Test
    func `should fail on a file that's empty, cut short, or not env's`() {
        #expect(EnvironmentImport.parse(Data(), names: ["CODEX_HOME"]) == .failed("the shell wrote no environment"))
        #expect(EnvironmentImport.parse(Data("CODEX_HOME=/x\0".utf8), names: ["CODEX_HOME"])
                == .failed("the shell's environment ended before ClaudeBar's end marker"))
        #expect(EnvironmentImport.parse(Data("CODEX_HOME=/x\0noise\0@@CLAUDEBAR_ENV_END@@".utf8), names: ["CODEX_HOME"])
                == .failed("the shell's environment had an entry without a name"))
    }

    @Test
    func `should build the shell command from SHELL, or bash without it`() {
        #expect(EnvironmentImport.command(shell: "/usr/bin/zsh", file: "/tmp/claudebar-env.Ab12/env")
                == ["/usr/bin/zsh", "-l", "-i", "-c",
                    "env -0 > /tmp/claudebar-env.Ab12/env; printf %s @@CLAUDEBAR_ENV_END@@ >> /tmp/claudebar-env.Ab12/env"])
        #expect(EnvironmentImport.command(shell: nil, file: "/tmp/x/env").first == "/bin/bash")
        #expect(EnvironmentImport.command(shell: "", file: "/tmp/x/env").first == "/bin/bash")
    }
}

#if os(Linux)
/// The import through a shell it really runs: here a stand-in for the
/// person's shell that sets a variable, hangs or fails, then runs the command.
/// One at a time: a script written while another test forks can't be run
/// until the fork's copy of the open file is closed (ETXTBSY).
@Suite(.serialized)
struct EnvironmentImportShellTests {
    private func shell(_ body: String) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("probe-shell-\(UUID().uuidString)")
        // Called as `<shell> -l -i -c <command>`: the command is $4.
        try "#!/bin/sh\n\(body)\nexec /bin/sh -c \"$4\"\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    private func envFolders() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []).filter { $0.hasPrefix("claudebar-env.") })
    }

    @Test
    func `should read the names the shell sets, and remove its folder`() throws {
        let before = envFolders()

        let outcome = EnvironmentImport.importing(names: ["PROBE_SHELL_TEST", "PROBE_SHELL_UNSET"],
                                                  shell: try shell("export PROBE_SHELL_TEST='from the shell'"))

        #expect(outcome == .values(["PROBE_SHELL_TEST": "from the shell"]))
        #expect(envFolders().subtracting(before).isEmpty)
    }

    @Test
    func `should give up on a shell that doesn't finish in time`() throws {
        let started = ContinuousClock.now

        let outcome = EnvironmentImport.importing(names: ["PROBE_SHELL_TEST"], shell: try shell("sleep 30"), timeout: .seconds(1))

        #expect(outcome == .failed("timed out after 1 s"))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test
    func `should fail when the shell exits with an error`() throws {
        #expect(EnvironmentImport.importing(names: ["PROBE_SHELL_TEST"], shell: try shell("exit 7")) == .failed("the shell exited with 7"))
    }

    @Test
    func `should fail when the shell can't be started`() {
        #expect(EnvironmentImport.importing(names: ["PROBE_SHELL_TEST"], shell: "/nonexistent/shell")
                == .failed("couldn't start /nonexistent/shell: No such file or directory"))
    }
}
#endif

