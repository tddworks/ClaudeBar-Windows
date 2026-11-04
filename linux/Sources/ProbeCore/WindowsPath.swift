public enum WindowsPath {
    /// A resolved Linux path in Windows form (design, *Folders shared with
    /// Windows*): on a drive, its mount's `path=` and the rest; on a drive
    /// without one, `wslpath -w`; on the distro's own disk,
    /// `\\wsl.localhost\<distro><path>`. Nil when a drive path can't be
    /// mapped, and always under a guessed drive rule, so the source fails closed.
    public static func of(_ path: String, rule: DriveRule, distro: String, wslpath: (String) -> String?) -> String? {
        switch rule {
        case .table(let table):
            if let drive = table.drive(containing: path) {
                guard let root = drive.windowsRoot else { return wslpath(path) }
                let rest = MountTable.trimmed(path).dropFirst(drive.point == "/" ? 1 : drive.point.count + 1)
                guard !rest.isEmpty else { return root }
                return (root.hasSuffix("\\") ? root : root + "\\") + backslashed(String(rest))
            }
        case .guess:
            if rule.isOnDrive(path) { return nil }
        }
        return "\\\\wsl.localhost\\" + distro + backslashed(MountTable.trimmed(path))
    }

    private static func backslashed(_ path: String) -> String {
        String(path.map { $0 == "/" ? "\\" : $0 })
    }
}
