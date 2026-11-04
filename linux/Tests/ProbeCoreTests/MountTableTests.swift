import Testing
@testable import ProbeCore

/// The design's mount rule, over mountinfo text: which mounts are a Windows
/// drive, and which paths are on one.
@Suite
struct MountTableTests {
    @Test
    func `should find the PC's drives, and not WSL's own mounts`() throws {
        let table = MountTable(mountinfo: try fixture("mountinfo-ubuntu.txt"))

        #expect(table.drives.map(\.point) == ["/mnt/c", "/mnt/d", "/mnt/e", "/mnt/h"])
        #expect(table.drives.first?.windowsRoot == "C:\\")
        for path in ["/mnt/wsl", "/mnt/wslg", "/mnt/wslg/distro", "/usr/lib/wsl/drivers", "/"] {
            #expect(table.drive(containing: path) == nil, "\(path)")
        }
    }

    @Test
    func `should find drives under another automount root`() throws {
        let table = MountTable(mountinfo: try fixture("mountinfo-win-root.txt"))

        #expect(table.drive(containing: "/win/c")?.windowsRoot == "C:\\")
        #expect(table.drive(containing: "/mnt/c") == nil)
    }

    @Test
    func `should find drives at the root, by whole names`() throws {
        let table = MountTable(mountinfo: try fixture("mountinfo-root.txt"))

        #expect(table.drive(containing: "/c/Users")?.point == "/c")
        #expect(table.drive(containing: "/cache") == nil)
    }

    @Test
    func `should take a WSL 1 drvfs line as a drive, and undo mountinfo's escapes`() throws {
        let table = MountTable(mountinfo: try fixture("mountinfo-drvfs.txt"))

        #expect(table.drives == [
            MountTable.Drive(point: "/mnt/c", windowsRoot: nil),
            MountTable.Drive(point: "/mnt/my drive", windowsRoot: "D:\\My Data\\"),
        ])
    }

    @Test
    func `should match a path by whole names, trailing slashes aside`() throws {
        let table = MountTable(mountinfo: try fixture("mountinfo-ubuntu.txt"))

        #expect(table.drive(containing: "/mnt/cache") == nil)
        #expect(table.drive(containing: "/mnt/c/")?.point == "/mnt/c")
        #expect(table.drive(containing: "/mnt/c")?.point == "/mnt/c")
        #expect(table.drive(containing: "/mnt/c/Users/me")?.point == "/mnt/c")
    }

    @Test
    func `should find no drives where none is mounted`() throws {
        #expect(MountTable(mountinfo: try fixture("mountinfo-none.txt")).drives.isEmpty)
    }

    @Test
    func `should guess the drives from wslpath's C drive when mountinfo can't be read`() {
        let mnt = DriveRule.guess(cDrive: "/mnt/c/")
        #expect(mnt.isOnDrive("/mnt/c/x"))
        #expect(mnt.isOnDrive("/mnt/z"))
        #expect(!mnt.isOnDrive("/mnt/wsl"))
        #expect(!mnt.isOnDrive("/mnt"))
        #expect(!mnt.isOnDrive("/home"))

        let root = DriveRule.guess(cDrive: "/c/")
        #expect(root.isOnDrive("/c/x"))
        #expect(!root.isOnDrive("/home"))
        #expect(!root.isOnDrive("/"))
    }
}
