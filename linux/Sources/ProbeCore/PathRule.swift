public enum PathRule {
    /// `PATH` without the entries on a drive: WSL appends Windows' `PATH`, and a
    /// Windows npm install's extensionless shim would be found before a Linux tool.
    public static func withoutDrives(_ path: String, _ rule: DriveRule) -> String {
        path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
            .filter { !rule.isOnDrive($0) }.joined(separator: ":")
    }
}
