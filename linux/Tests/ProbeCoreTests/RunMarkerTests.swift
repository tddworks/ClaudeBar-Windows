import Foundation
import Testing
@testable import ProbeCore

/// The run's marker, as `/proc/<pid>/environ` shows it: the environment at
/// `execve`, NUL-separated.
@Suite
struct RunMarkerTests {
    @Test
    func `should find the marker among NUL-separated variables, and only by its whole name`() {
        let environ = Data("PATH=/usr/bin\0CLAUDEBAR_WSL_RUN=abc\0XCLAUDEBAR_WSL_RUN=no\0".utf8)

        #expect(RunMarker.value(inEnviron: environ) == "abc")
        #expect(RunMarker.matches(environ, .run("abc")))
        #expect(!RunMarker.matches(environ, .run("abd")))
        #expect(RunMarker.matches(environ, .all))
        #expect(!RunMarker.matches(Data("PATH=/usr/bin\0".utf8), .all))
    }

    @Test
    func `should find nothing in a zombie's empty environ`() {
        #expect(RunMarker.value(inEnviron: Data()) == nil)
        #expect(!RunMarker.matches(Data(), .all))
    }

    @Test
    func `should take a run id of 32 lowercase hex digits only`() {
        #expect(RunMarker.isRunId("0123456789abcdef0123456789abcdef"))
        #expect(!RunMarker.isRunId("0123456789ABCDEF0123456789ABCDEF"))
        #expect(!RunMarker.isRunId("0123456789abcdef0123456789abcde"))
        #expect(!RunMarker.isRunId("0123456789abcdef0123456789abcdeg"))
        #expect(!RunMarker.isRunId("all"))
    }
}
