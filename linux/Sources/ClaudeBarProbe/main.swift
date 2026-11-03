import ClaudeBarShared
import Diagnostics
import DataSources
import Foundation
import Leaderboard
import Providers

// claudebar-probe: what ClaudeBar reads on this Linux system, as JSON.
//
// --json (the default): the HUD's answer after refreshing every login (the
//   object `cbw_hud_reading` returns, without `state`), the last 30 days'
//   tokens per provider-day as an upload counts them (`DailyTokens`), the
//   providers found, the time zone the days are in, and how long each part took.
// --where: the environment a CLI is looked for in (HOME, SHELL, PATH) and
//   where ClaudeBar's own locator finds each tool.
// --settings <file>: ClaudeBar's settings file to read (default
//   ~/.claudebar/settings.json), to turn providers on or off.
// --deadline <seconds>: answer with what has been read by then (default 60),
//   with `timedOut: true`, if the refresh hasn't finished.
// --days <n>: the days of tokens to read (default 30, what joining sends).

let argv = Array(CommandLine.arguments.dropFirst())
let arguments = Set(argv)
func option(_ name: String) -> String? {
    argv.firstIndex(of: name).flatMap { argv.index(after: $0) < argv.endIndex ? argv[argv.index(after: $0)] : nil }
}

func emit(_ object: Any) {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("claudebar-probe: \(error)\n".utf8))
        exit(1)
    }
}

func elapsed(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

if arguments.contains("--where") {
    let environment = ProcessInfo.processInfo.environment
    let tools = ["claude", "codex", "omp", "gemini", "opencode", "kimi", "grok", "amp", "node"]
    var located: [String: Any] = [:]
    for tool in tools { located[tool] = DataSources.locate(tool) ?? NSNull() }
    emit(["home": FileManager.default.homeDirectoryForCurrentUser.path,
          "envHome": environment["HOME"] ?? NSNull(),
          "shell": environment["SHELL"] ?? NSNull(),
          "path": (environment["PATH"] ?? "").split(separator: ":").map(String.init),
          "located": located])
    exit(0)
}

let started = ContinuousClock.now
let calendar = DataSources.calendar()
let now = Date()
let deadline = option("--deadline").flatMap(Double.init) ?? 60
let days = option("--days").flatMap(Int.init) ?? 30

let settings = option("--settings").map { ClaudeBarSettings(url: URL(fileURLWithPath: $0)) } ?? ClaudeBarSettings()
let hud = HudMonitor(settings: settings)
var answered = false

/// Prints the answer with the logs' tokens, once, and exits.
@MainActor func report(_ answer: HudMonitor.Answer, timedOut: Bool) async {
    guard !answered else { return }
    answered = true
    let hudSeconds = elapsed(since: started)
    let tokensStarted = ContinuousClock.now
    let logs = ProviderTokenLogs()
    let month = await logs.days(in: DateRange.last(days, endingOn: now, calendar: calendar))
    let tokens = DailyTokens.summed(month, providers: logs.providersWithLogs, calendar: calendar)
    let tokensSeconds = elapsed(since: tokensStarted)
    do {
        var output = try answer.json()
        output["tokens"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tokens))
        output["providersWithLogs"] = logs.providersWithLogs.sorted()
        output["detected"] = ProviderCatalog().detect().map(\.id).sorted()
        output["logFile"] = AppLog.logFileURL.path
        output["timeZone"] = calendar.timeZone.identifier
        output["timedOut"] = timedOut
        output["seconds"] = ["hud": hudSeconds, "tokens": tokensSeconds, "total": elapsed(since: started)]
        emit(output)
    } catch {
        FileHandle.standardError.write(Data("claudebar-probe: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

Task { @MainActor in await report(await hud.refresh(), timedOut: false) }
Task { @MainActor in
    try? await Task.sleep(for: .seconds(deadline))
    await report(hud.answer(), timedOut: true)
}
try? await Task.sleep(for: .seconds(deadline + 60))
FileHandle.standardError.write(Data("claudebar-probe: no answer \(Int(deadline + 60)) s after starting\n".utf8))
exit(2)
