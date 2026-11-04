import DataSources
import Foundation
import Providers

/// The variables the definitions name, as the person's login shell sets them
/// (design, *The environment*). With `wsl.exe -e` there's no shell, so a
/// `CODEX_HOME` exported in `.bashrc` would never reach the probe, and it
/// would read `~/.codex` and compare the wrong roots with Windows'.
public enum EnvironmentImport {
    /// Written after `env -0`'s entries, so a file cut short is told from a whole one.
    public static let end = "@@CLAUDEBAR_ENV_END@@"

    public enum Outcome: Equatable, Sendable {
        case values([String: String])
        case failed(String)
    }

    /// Every `${NAME` in the definitions' own encoding, valid as a shell
    /// name, except `PATH`: the probe's `PATH` is its own, without the
    /// drives, and a shell's has WSL's Windows entries back in it.
    public static func names(usedBy definitions: [ProviderDefinition]) -> [String] {
        var names = Set<String>()
        for definition in definitions {
            guard let data = try? JSONEncoder().encode(definition) else { continue }
            var rest = String(decoding: data, as: UTF8.self)[...]
            while let start = rest.range(of: "${") {
                let name = String(rest[start.upperBound...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
                if name != "PATH", LoginShellEnvironment.isValidName(name) { names.insert(name) }
                rest = rest[start.upperBound...]
            }
        }
        return names.sorted()
    }

    /// The login shell's command: `$SHELL`, or bash without one, as ClaudeBar's
    /// `LinuxProcesses` chooses. `file` comes from `mkdtemp` with a safe
    /// template, so it needs no quoting in bash, zsh or fish.
    public static func command(shell: String?, file: String) -> [String] {
        let binary = (shell ?? "").isEmpty ? "/bin/bash" : shell!
        return [binary, "-l", "-i", "-c", "env -0 > \(file); printf %s \(end) >> \(file)"]
    }

    /// The file only `env -0` and the end marker wrote: anything else in it fails the import.
    public static func parse(_ file: Data, names: [String]) -> Outcome {
        guard !file.isEmpty else { return .failed("the shell wrote no environment") }
        var entries = file.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard entries.last == end else { return .failed("the shell's environment ended before ClaudeBar's end marker") }
        entries.removeLast()
        let wanted = Set(names)
        var values: [String: String] = [:]
        for text in entries {
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else {
                return .failed("the shell's environment had an entry without a name")
            }
            let name = String(text[..<equals]), value = String(text[text.index(after: equals)...])
            if wanted.contains(name), !value.isEmpty { values[name] = value }
        }
        return .values(values)
    }
}
