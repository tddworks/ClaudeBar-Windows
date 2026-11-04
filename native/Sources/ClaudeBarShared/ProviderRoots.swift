import DataSources
import Foundation
import Providers

/// The places a provider's default login is read from, on one side
/// (docs/plans/2026-11-03-wsl-design.md, Folders shared with Windows): its
/// account folder, any other folder an account setting names, and the files
/// its data sources read (`credentials`); and its usage records, each up to
/// the folder before its first wildcard (`logs`). Each is expanded as
/// ClaudeBar expands it (`DataSources.expandPath`).
///
/// ClaudeBar has no public list of the files a definition reads, so the
/// definition's own encoding is read: the path-shaped strings under `path`,
/// `file`, `files` and `glob`, and for `logs` only those under `records`
/// (Claude's history also names `.claude.json`, to tell a free plan, which
/// isn't a record). ProviderRootsTests pins the result.
public struct ProviderRoots: Codable, Equatable, Sendable {
    public let provider: String
    public let credentials: [String]
    public let logs: [String]

    public init(provider: String, credentials: [String], logs: [String]) {
        self.provider = provider
        self.credentials = credentials
        self.logs = logs
    }

    public static func of(_ definition: ProviderDefinition, homeDirectory: URL,
                          environment: @escaping @Sendable (String) -> String?) -> ProviderRoots {
        let values = definition.defaultAccountValues
        let expand = { DataSources.expandPath($0, homeDirectory: homeDirectory, environment: environment) }
        var credentials = values[ProviderDefinition.Accounts.folderValue].map { [$0] } ?? []
        credentials += definition.accountSettings.filter { if case .path = $0.kind { true } else { false } }.compactMap { values[$0.id] }
        if let sources = try? definition.dataSources(forDefaultAccount: values) { credentials += paths(in: sources) }
        let logs = definition.usageHistory(forDefaultAccount: values).map { paths(in: $0, under: "records") } ?? []
        return ProviderRoots(provider: definition.id,
                             credentials: unique(credentials.map(expand)),
                             logs: unique(logs.map(expand).map(folderBeforeWildcard)))
    }

    static let pathKeys: Set<String> = ["path", "file", "files", "glob"]

    /// The path-shaped strings under `pathKeys` in `value`'s encoding, in
    /// key order; with `ancestor`, only those inside an object under that key.
    static func paths(in value: some Encodable, under ancestor: String? = nil) -> [String] {
        guard let data = try? JSONEncoder().encode(value), let tree = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var found: [String] = []
        func walk(_ node: Any, key: String?, inside: Bool) {
            switch node {
            case let object as [String: Any]:
                for (name, child) in object.sorted(by: { $0.key < $1.key }) { walk(child, key: name, inside: inside || name == ancestor) }
            case let list as [Any]:
                for child in list { walk(child, key: key, inside: inside) }
            case let text as String where inside && key.map(pathKeys.contains) == true && looksLikePath(text):
                found.append(text)
            default:
                break
            }
        }
        walk(tree, key: nil, inside: ancestor == nil)
        return found
    }

    /// A place, not a JSON path or a value: home, absolute, a variable, the
    /// platform's app data, or a drive; never one still naming an account value.
    static func looksLikePath(_ text: String) -> Bool {
        guard !text.contains("{{account.") else { return false }
        if text.hasPrefix("~") || text.hasPrefix("/") || text.hasPrefix("${") || text.hasPrefix("{{platform.appData}}") { return true }
        let chars = Array(text)
        return chars.count >= 3 && chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/")
    }

    static func folderBeforeWildcard(_ path: String) -> String {
        guard let star = path.firstIndex(where: { $0 == "*" || $0 == "?" || $0 == "[" }) else { return path }
        let before = path[..<star]
        guard let slash = before.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return String(before) }
        return String(before[..<slash])
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

/// What the app writes before each launch (`--windows-roots`): this PC's
/// roots per provider, each resolved through links and junctions.
public struct WindowsRoots: Codable, Equatable, Sendable {
    public let version: String
    public let distro: String
    public let providers: [ProviderRoots]

    public init(version: String, distro: String, providers: [ProviderRoots]) {
        self.version = version
        self.distro = distro
        self.providers = providers
    }
}
