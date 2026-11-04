import Foundation
import Testing
@testable import ClaudeBarWindows

/// What `wsl.exe` writes when it lists the distros, and the command lines
/// ClaudeBar gives it (design, *The probe* and *Running it*).
@Suite
struct WslCommandTests {
    private func utf16(_ text: String) -> Data { text.data(using: .utf16LittleEndian)! }

    @Test func `should read wsl -l -q's UTF-16LE, with no BOM and CRLF`() {
        #expect(WslCommand.distros(in: utf16("Ubuntu-26.04\r\ndocker-desktop\r\n")) == ["Ubuntu-26.04", "docker-desktop"])
    }

    @Test func `should read UTF-8 too, which WSL_UTF8=1 asks for`() {
        #expect(WslCommand.distros(in: Data("Ubuntu-26.04\r\n".utf8)) == ["Ubuntu-26.04"])
    }

    @Test func `should read nothing from an empty list`() { #expect(WslCommand.distros(in: Data()).isEmpty) }

    @Test func `should drop a byte order mark, UTF-16LE's or UTF-8's`() {
        #expect(WslCommand.distros(in: Data([0xFF, 0xFE]) + utf16("Ubuntu-26.04\r\n")) == ["Ubuntu-26.04"])
        #expect(WslCommand.distros(in: Data([0xEF, 0xBB, 0xBF]) + Data("Ubuntu-26.04\n".utf8)) == ["Ubuntu-26.04"])
    }

    @Test func `should leave out Docker's and Rancher's own distros`() {
        #expect(WslCommand.readable(["Ubuntu-26.04", "docker-desktop", "docker-desktop-data", "Rancher-Desktop", "rancher-desktop-data"]) == ["Ubuntu-26.04"])
    }

    @Test func `should mark the run with env, before the probe, never in WSLENV`() {
        #expect(WslCommand.probe(distro: "Ubuntu-26.04", probe: "/mnt/c/a b/claudebar-probe", run: "0123456789abcdef0123456789abcdef",
                                 windowsRoots: "/mnt/c/r.json", deadline: 60, logsOnly: false)
                == ["-d", "Ubuntu-26.04", "-e", "env", "CLAUDEBAR_WSL_RUN=0123456789abcdef0123456789abcdef", "/mnt/c/a b/claudebar-probe",
                    "--json", "--windows-roots", "/mnt/c/r.json", "--deadline", "60"])
    }

    @Test func `should read the logs alone with no deadline, for the uploader`() {
        #expect(WslCommand.probe(distro: "Ubuntu-26.04", probe: "/p", run: "0123456789abcdef0123456789abcdef",
                                 windowsRoots: "/r.json", deadline: 60, logsOnly: true)
                == ["-d", "Ubuntu-26.04", "-e", "env", "CLAUDEBAR_WSL_RUN=0123456789abcdef0123456789abcdef", "/p",
                    "--logs-only", "--windows-roots", "/r.json"])
    }

    @Test func `should end a run without the marker`() {
        #expect(WslCommand.end(distro: "Ubuntu-26.04", probe: "/p", target: "all") == ["-d", "Ubuntu-26.04", "-e", "/p", "--end", "all"])
    }

    @Test func `should ask the distro for a Windows path's Linux one`() {
        #expect(WslCommand.wslpath(distro: "Ubuntu-26.04", path: #"C:\Program Files\ClaudeBar"#)
                == ["-d", "Ubuntu-26.04", "-e", "wslpath", "-u", #"C:\Program Files\ClaudeBar"#])
    }

    @Test func `should list every distro, or the running ones, starting none`() {
        #expect(WslCommand.list(runningOnly: false) == ["-l", "-q"])
        #expect(WslCommand.list(runningOnly: true) == ["-l", "--running", "-q"])
    }

    @Test func `should name a run with 32 lowercase hex digits, a new one each time`() {
        let first = WslCommand.newRun(), second = WslCommand.newRun()
        #expect(first.count == 32 && first.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(first != second)
    }

    @Test func `should quote a command line as wsl.exe reads it back`() {
        #expect(WslCommand.commandLine(#"C:\Windows\System32\wsl.exe"#,
                                       ["-d", "Ubuntu-26.04", "-e", "wslpath", "-u", #"C:\Users\Jo Smith\AppData\Local\ClaudeBar\wsl\"#, "", #"say "hi""#])
                == #""C:\Windows\System32\wsl.exe" -d Ubuntu-26.04 -e wslpath -u "C:\Users\Jo Smith\AppData\Local\ClaudeBar\wsl\\" "" "say \"hi\"""#)
    }

    @Test func `should name each distro's mutex as the app does`() {
        #expect(WslCommand.mutexName("Ubuntu-26.04") == #"Local\ClaudeBar.wsl.Ubuntu-26.04"#)
    }

    @Test func `should say the probe's own line first, else the first line`() {
        #expect(WslCommand.failureLine("wsl: Failed to start the systemd user session for 'me'.\nclaudebar-probe: no run marker\n") == "claudebar-probe: no run marker")
        #expect(WslCommand.failureLine("\n/bin/env: 'claudebar-probe': No such file or directory\n") == "/bin/env: 'claudebar-probe': No such file or directory")
    }
}
