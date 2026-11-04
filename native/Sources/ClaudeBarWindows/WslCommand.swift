import Foundation

/// What ClaudeBar asks `wsl.exe`, and how it reads the answers: the distros'
/// lists, the probe's command lines (the plan's *The probe's command line*),
/// and the per-distro mutex the app and the uploader share.
public enum WslCommand {
    /// `wsl.exe -l -q`, or `-l --running -q`; neither starts a distro.
    public static func list(runningOnly: Bool) -> [String] {
        runningOnly ? ["-l", "--running", "-q"] : ["-l", "-q"]
    }

    /// The distros a list names, in its order. `wsl.exe` writes UTF-16LE with
    /// CRLF and no BOM, or UTF-8 when `WSL_UTF8=1` is set for the account.
    public static func distros(in output: Data) -> [String] {
        text(in: output).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `wsl.exe`'s own text: UTF-16LE when the byte count is even and the
    /// second byte is 0, or after UTF-16LE's BOM; otherwise UTF-8, without its
    /// BOM. The Linux side's output, which `wsl.exe` passes through, is UTF-8.
    public static func text(in output: Data) -> String {
        let bytes = [UInt8](output)
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(decoding: utf16Units(bytes.dropFirst(2)), as: UTF16.self)
        }
        if bytes.count.isMultiple(of: 2), bytes.count >= 2, bytes[1] == 0 {
            return String(decoding: utf16Units(bytes[...]), as: UTF16.self)
        }
        let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes
        return String(decoding: body, as: UTF8.self)
    }

    private static func utf16Units(_ bytes: ArraySlice<UInt8>) -> [UInt16] {
        stride(from: bytes.startIndex, to: bytes.endIndex - 1, by: 2).map {
            UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
        }
    }

    /// The distros a person's tools could be in: not Docker Desktop's nor
    /// Rancher Desktop's own, which run their engines, never a person's CLIs.
    public static func readable(_ distros: [String]) -> [String] {
        distros.filter {
            let name = $0.lowercased()
            return !name.hasPrefix("docker-desktop") && !name.hasPrefix("rancher-desktop")
        }
    }

    /// One probe run, marked by `env` before the probe is exec'd, so the
    /// marker is in `/proc/<pid>/environ` of the probe and every child, and
    /// the person's `WSLENV` is untouched. `run` is 32 lowercase hex digits.
    public static func probe(distro: String, probe: String, run: String, windowsRoots: String,
                             deadline: Int, logsOnly: Bool) -> [String] {
        let mode = logsOnly ? ["--logs-only", "--windows-roots", windowsRoots]
                            : ["--json", "--windows-roots", windowsRoots, "--deadline", String(deadline)]
        return ["-d", distro, "-e", "env", "CLAUDEBAR_WSL_RUN=\(run)", probe] + mode
    }

    /// Ends the processes of one run (`target` its id), or of every run
    /// (`all`). Without the marker, so it never matches itself.
    public static func end(distro: String, probe: String, target: String) -> [String] {
        ["-d", distro, "-e", probe, "--end", target]
    }

    /// The Linux path of a Windows path, as the distro mounts it.
    public static func wslpath(distro: String, path: String) -> [String] {
        ["-d", distro, "-e", "wslpath", "-u", path]
    }

    /// A new run's id: 32 lowercase hex digits.
    public static func newRun() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The mutex a probe run holds in a distro, the app's and the uploader's alike.
    public static func mutexName(_ distro: String) -> String {
        #"Local\ClaudeBar.wsl."# + distro
    }

    /// The line a person reads when a run fails: the probe's own
    /// (`claudebar-probe: <reason>`), else the first that isn't empty, since a
    /// stopped distro's start writes the systemd line first.
    public static func failureLine(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.first { $0.hasPrefix("claudebar-probe:") } ?? lines.first ?? ""
    }

    /// The command line `CreateProcessW` gets, which `wsl.exe` parses back into
    /// `executable` and `arguments` by the C runtime's rules: each argument bare
    /// when it needs nothing, else in quotes with its quotes and the
    /// backslashes before them escaped.
    public static func commandLine(_ executable: String, _ arguments: [String]) -> String {
        (["\"\(executable)\""] + arguments.map(quoted)).joined(separator: " ")
    }

    static func quoted(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { " \t\n\u{0B}\"".contains($0) }) else { return argument }
        var result = "\""
        var backslashes = 0
        for character in argument {
            if character == "\\" {
                backslashes += 1
                continue
            }
            if character == "\"" {
                result += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
            } else {
                result += String(repeating: "\\", count: backslashes) + String(character)
            }
            backslashes = 0
        }
        return result + String(repeating: "\\", count: backslashes * 2) + "\""
    }
}
