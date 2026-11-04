import Foundation

/// The drive mounts of a distro (design, *PATH*, the mount rule): each line of
/// `/proc/self/mountinfo` whose filesystem is `drvfs`, or `9p` with
/// `aname=drvfs` among its options (split on `,`, then `;`). Its mount point,
/// unescaped, is the root; `path=` is the Windows folder it shows.
public struct MountTable: Equatable, Sendable {
    public struct Drive: Equatable, Sendable {
        public let point: String
        public let windowsRoot: String?

        public init(point: String, windowsRoot: String?) {
            self.point = point
            self.windowsRoot = windowsRoot
        }
    }

    public let drives: [Drive]

    public init(mountinfo: String) {
        drives = mountinfo.split(separator: "\n").compactMap { line in
            // The optional fields end at a lone `-`; the filesystem's own
            // fields follow it. Spaces inside a field are escaped (`\040`).
            let halves = line.components(separatedBy: " - ")
            guard halves.count == 2 else { return nil }
            let left = halves[0].split(separator: " ")
            let right = halves[1].split(separator: " ", maxSplits: 2)
            guard left.count >= 5, right.count == 3 else { return nil }
            let options = right[2].split(separator: ",").flatMap { $0.split(separator: ";") }.map(String.init)
            guard right[0] == "drvfs" || (right[0] == "9p" && options.contains("aname=drvfs")) else { return nil }
            let windows = options.first { $0.hasPrefix("path=") }.map { Self.unescape(String($0.dropFirst(5))) }
            return Drive(point: Self.trimmed(Self.unescape(String(left[4]))), windowsRoot: windows)
        }
    }

    /// The drive a path is on, by whole names; the longest mount point wins.
    public func drive(containing path: String) -> Drive? {
        let path = Self.trimmed(path)
        return drives.filter { Self.isUnder(path, $0.point) }.max { $0.point.count < $1.point.count }
    }

    /// Whether `path` is `root` or inside it, by whole names. Both trimmed.
    static func isUnder(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// mountinfo's escapes, which the kernel writes for the four bytes that
    /// would break a field: `\040` a space, `\011` a tab, `\012` a newline,
    /// `\134` a backslash. Any other backslash is itself (`path=C:\`).
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        let escapes: [String: String] = ["040": " ", "011": "\t", "012": "\n", "134": "\\"]
        var result = ""
        var rest = text[...]
        while let slash = rest.firstIndex(of: "\\") {
            result += rest[..<slash]
            let digits = rest[rest.index(after: slash)...].prefix(3)
            if let byte = escapes[String(digits)] {
                result += byte
                rest = rest[digits.endIndex...]
            } else {
                result += "\\"
                rest = rest[rest.index(after: slash)...]
            }
        }
        return result + rest
    }

    /// A path without its trailing slashes, `/` itself kept.
    static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Which paths are on a Windows drive: from the mount table, or, when it
/// can't be read, guessed from `wslpath -u 'C:\'`: that folder's parent,
/// then a one-letter name (`/mnt/c/` gives `/mnt/<letter>`, `/c/` gives `/<letter>`).
public enum DriveRule: Equatable, Sendable {
    case table(MountTable)
    case guess(cDrive: String)

    public func isOnDrive(_ path: String) -> Bool {
        switch self {
        case .table(let table):
            return table.drive(containing: path) != nil
        case .guess(let cDrive):
            let drive = MountTable.trimmed(cDrive)
            guard let slash = drive.lastIndex(of: "/") else { return false }
            let parent = slash == drive.startIndex ? "/" : String(drive[..<slash])
            let path = MountTable.trimmed(path)
            guard path != parent, MountTable.isUnder(path, parent) else { return false }
            let name = path.dropFirst(parent == "/" ? 1 : parent.count + 1).prefix { $0 != "/" }
            return name.count == 1 && name.first!.isASCII && name.first!.isLetter
        }
    }
}
