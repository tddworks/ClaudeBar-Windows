import ClaudeBarShared
import Foundation
import Glibc
import ProbeCore

// claudebar-probe: ClaudeBar for Windows' reader inside a WSL distro
// (docs/plans/2026-11-03-wsl-design.md). Stdout is one ProbeReading or
// nothing; exit 1 is bad arguments or an I/O error, 2 no answer 60 s after
// the deadline, 3 no run marker.

func stop(_ code: Int32, _ reason: String) -> Never {
    FileHandle.standardError.write(Data("claudebar-probe: \(reason)\n".utf8))
    exit(code)
}

let arguments: ProbeArguments
do {
    arguments = try ProbeArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    stop(1, "\(error)")
}

if case .end(let target) = arguments.mode {
    // Run without the marker, so it never matches itself.
    exit(EndRun.end(target, sparing: getpid()) ? 0 : 1)
}

guard let id = readProcFile("/proc/self/environ").flatMap(RunMarker.value(inEnviron:)), !id.isEmpty else {
    stop(3, "no run marker (\(RunMarker.name)), so its processes couldn't be found again")
}

// The watchdog, on a thread of its own: a stuck refresh can hold the main
// actor. 60 s after the deadline it ends the run's other processes and exits
// 2 with nothing on stdout: a run without an answer replaces nothing.
let limit = arguments.deadline + 60
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: limit)
    EndRun.end(.run(id), sparing: getpid())
    stop(2, "no answer 60 s after the \(Int(arguments.deadline)) s deadline")
}

let reading: ProbeReading
do {
    reading = try await Probe.run(arguments, marker: id)
} catch {
    EndRun.end(.run(id), sparing: getpid())
    stop(error.code, error.reason)
}

do {
    var data = try ProbeReading.encoder().encode(reading)
    data.append(UInt8(ascii: "\n"))
    try FileHandle.standardOutput.write(contentsOf: data)
} catch {
    EndRun.end(.run(id), sparing: getpid())
    stop(1, "couldn't write the answer: \(error)")
}

// Nothing the run started outlives it: its CLIs, and anything the shell files started.
EndRun.end(.run(id), sparing: getpid())
exit(0)
