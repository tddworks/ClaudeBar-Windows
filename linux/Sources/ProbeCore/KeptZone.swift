import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The zone the distro's kept days were counted in (design, *Kept days carry
/// no zone*): ClaudeBar keeps each closed day under its label and starts over
/// only when the log's fingerprint changes, which holds no zone. So before
/// anything reads days in another zone than the last run that read them, the
/// ledger's pages go; the scans, kept per zone, stay.
public struct KeptZone {
    /// `<home>/.local/share/ClaudeBar/wsl-zone`.
    public let zoneFile: URL
    /// `<home>/.claudebar/usage-history`, where `FileLedgerStore` keeps a page per login.
    public let ledger: URL

    /// `<home>/.local/share/ClaudeBar/wsl-zone` and `<home>/.claudebar/usage-history`.
    public init(home: URL) {
        zoneFile = home.appendingPathComponent(".local/share/ClaudeBar/wsl-zone")
        ledger = home.appendingPathComponent(".claudebar/usage-history")
    }

    /// The distro's own zone, from `/etc/localtime`'s link into a zoneinfo
    /// folder; nil when it isn't one. The link's own target names the zone,
    /// not the file it ends at: `Etc/UTC` may itself link to `Etc/UCT`.
    public static func distroZone(localtime: String = "/etc/localtime") -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: localtime) else { return nil }
        let base = URL(fileURLWithPath: localtime).deletingLastPathComponent()
        let file = target.hasPrefix("/") ? URL(fileURLWithPath: target) : base.appendingPathComponent(target)
        guard let folder = resolved(file.deletingLastPathComponent().path) else { return nil }
        let path = folder + "/" + file.lastPathComponent
        guard let marker = path.range(of: "/zoneinfo/", options: .backwards) else { return nil }
        let name = String(path[marker.upperBound...])
        return name.isEmpty ? nil : name
    }

    /// Before reading days in `zone`: when the kept days were counted in
    /// another (`wsl-zone`, or `own` when no run recorded one), removes every
    /// `*.json` page directly in the ledger's folder, then records `zone`.
    /// True when pages were removed. Throws `Failure` when one couldn't be, and records nothing.
    public func prepare(counting zone: String, own: String?) throws(Failure) -> Bool {
        let kept = recorded ?? own
        var removed = false
        if kept != zone {
            for page in pages() {
                guard unlink(page) == 0 else {
                    let reason = String(cString: strerror(errno))
                    throw Failure(path: page, reason: reason)
                }
                removed = true
            }
        }
        if recorded != zone { try record(zone) }
        return removed
    }

    /// A page `prepare` couldn't remove, or `wsl-zone` it couldn't write:
    /// `<path>: <strerror>`, the probe's diagnostic's detail.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let path: String
        public let reason: String
        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
        public var description: String { "\(path): \(reason)" }
    }

    /// The zone the last run that read days recorded, trimmed; nil without one.
    var recorded: String? {
        guard let text = try? String(contentsOf: zoneFile, encoding: .utf8) else { return nil }
        let zone = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return zone.isEmpty ? nil : zone
    }

    /// Each `*.json` file directly in the ledger's folder, by name.
    private func pages() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ledger.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let path = ledger.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR else { return nil }
            return path
        }
    }

    private func record(_ zone: String) throws(Failure) {
        do {
            try FileManager.default.createDirectory(at: zoneFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(zone)\n".utf8).write(to: zoneFile, options: .atomic)
        } catch {
            throw Failure(path: zoneFile.path, reason: error.localizedDescription)
        }
    }

    /// The path with every symlink followed, or nil when it doesn't exist.
    private static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
