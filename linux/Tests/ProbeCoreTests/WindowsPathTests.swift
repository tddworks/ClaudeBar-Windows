import Testing
@testable import ProbeCore

/// A distro's root in the form Windows names it, for the shared-root check.
@Suite
struct WindowsPathTests {
    private let noWslpath: (String) -> String? = { _ in Issue.record("wslpath -w wasn't needed"); return nil }

    @Test
    func `should map a path on a drive through its mount's path`() throws {
        let rule = DriveRule.table(MountTable(mountinfo: try fixture("mountinfo-ubuntu.txt")))

        #expect(WindowsPath.of("/mnt/c/Users/me/.claude", rule: rule, distro: "Ubuntu-26.04", wslpath: noWslpath)
                == "C:\\Users\\me\\.claude")
        #expect(WindowsPath.of("/mnt/h", rule: rule, distro: "Ubuntu-26.04", wslpath: noWslpath) == "H:\\")
    }

    @Test
    func `should map an escaped path option and keep its own separator`() throws {
        let rule = DriveRule.table(MountTable(mountinfo: try fixture("mountinfo-drvfs.txt")))

        #expect(WindowsPath.of("/mnt/my drive/wsl/.claude", rule: rule, distro: "D", wslpath: noWslpath)
                == "D:\\My Data\\wsl\\.claude")
    }

    @Test
    func `should map a path on the distro's own disk to its wsl.localhost share`() throws {
        let rule = DriveRule.table(MountTable(mountinfo: try fixture("mountinfo-ubuntu.txt")))

        #expect(WindowsPath.of("/home/me/.claude", rule: rule, distro: "Ubuntu-26.04", wslpath: noWslpath)
                == "\\\\wsl.localhost\\Ubuntu-26.04\\home\\me\\.claude")
        #expect(WindowsPath.of("/mnt/cache/x", rule: rule, distro: "Ubuntu-26.04", wslpath: noWslpath)
                == "\\\\wsl.localhost\\Ubuntu-26.04\\mnt\\cache\\x")
    }

    @Test
    func `should ask wslpath for a drive without a path, and give nothing when it fails`() throws {
        let rule = DriveRule.table(MountTable(mountinfo: try fixture("mountinfo-drvfs.txt")))

        #expect(WindowsPath.of("/mnt/c/Users/me/.claude", rule: rule, distro: "D", wslpath: { "C:\\X\\" + ($0 == "/mnt/c/Users/me/.claude" ? "ok" : "no") })
                == "C:\\X\\ok")
        #expect(WindowsPath.of("/mnt/c/Users/me/.claude", rule: rule, distro: "D", wslpath: { _ in nil }) == nil)
    }

    @Test
    func `should fail closed on a drive under the guessed rule, and map the distro's disk`() {
        let rule = DriveRule.guess(cDrive: "/mnt/c/")

        #expect(WindowsPath.of("/mnt/c/Users/me/.claude", rule: rule, distro: "D", wslpath: { _ in "C:\\Users\\me\\.claude" }) == nil)
        #expect(WindowsPath.of("/home/me/.claude", rule: rule, distro: "D", wslpath: noWslpath) == "\\\\wsl.localhost\\D\\home\\me\\.claude")
    }
}
