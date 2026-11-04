import Testing
@testable import ProbeCore

/// The probe's command line, as the app builds it (the plan's contract).
@Suite
struct ProbeArgumentsTests {
    private let id = "0123456789abcdef0123456789abcdef"

    @Test
    func `should read a full run, with its roots file, deadline and the default 30 days`() throws {
        let arguments = try ProbeArguments.parse(["--json", "--windows-roots", "/x", "--deadline", "30"])

        #expect(arguments == ProbeArguments(mode: .json, windowsRoots: "/x", deadline: 30, days: 30))
    }

    @Test
    func `should default the deadline to 60 seconds`() throws {
        #expect(try ProbeArguments.parse(["--json", "--windows-roots", "/x"]).deadline == 60)
    }

    @Test
    func `should read a logs-only run`() throws {
        let arguments = try ProbeArguments.parse(["--logs-only", "--windows-roots", "/x"])

        #expect(arguments.mode == .logsOnly)
        #expect(arguments.windowsRoots == "/x")
    }

    @Test
    func `should read the days to read`() throws {
        #expect(try ProbeArguments.parse(["--logs-only", "--windows-roots", "/x", "--days", "400"]).days == 400)
    }

    @Test
    func `should read an end of one run, or of every run`() throws {
        #expect(try ProbeArguments.parse(["--end", id]).mode == .end(.run(id)))
        #expect(try ProbeArguments.parse(["--end", "all"]).mode == .end(.all))
    }

    @Test(arguments: [
        ([String](), "no mode: give --json, --logs-only or --end <id|all>"),
        (["--json", "--logs-only", "--windows-roots", "/x"], "more than one mode: give one of --json, --logs-only or --end"),
        (["--end"], "--end needs a run id or all"),
        (["--end", "0123456789ABCDEF0123456789ABCDEF"], "--end needs a run id of 32 lowercase hex digits, or all"),
        (["--end", "0123"], "--end needs a run id of 32 lowercase hex digits, or all"),
        (["--json", "--windows-roots", "/x", "--verbose"], "unknown option --verbose"),
        (["--json", "--windows-roots", "/x", "--deadline", "soon"], "--deadline needs a positive number of seconds"),
        (["--json", "--windows-roots", "/x", "--deadline", "0"], "--deadline needs a positive number of seconds"),
        (["--json", "--windows-roots", "/x", "--deadline", "-5"], "--deadline needs a positive number of seconds"),
        (["--json", "--windows-roots", "/x", "--deadline"], "--deadline needs a positive number of seconds"),
        (["--json", "--windows-roots", "/x", "--days", "0"], "--days needs a positive whole number"),
        (["--json"], "--json needs --windows-roots <file>"),
        (["--logs-only", "--windows-roots"], "--windows-roots needs a file"),
    ])
    func `should refuse a command line it can't run, saying why`(arguments: [String], reason: String) {
        #expect(throws: ProbeArguments.Invalid(reason)) { try ProbeArguments.parse(arguments) }
    }
}
