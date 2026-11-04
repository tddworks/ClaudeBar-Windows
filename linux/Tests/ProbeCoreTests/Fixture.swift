import Foundation

/// A file from `Fixtures/`, as text.
func fixture(_ name: String) throws -> String {
    String(decoding: try fixtureData(name), as: UTF8.self)
}

/// A file from `Fixtures/`, as bytes.
func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
    return try Data(contentsOf: url)
}

#if os(Linux)
import Glibc

/// Writes a file the tests then run, opened with `O_CLOEXEC`. Foundation's
/// `write(to:atomically:)` opens its file without it, so a child another
/// test starts at that moment keeps the file open for writing, and running
/// the file fails with ETXTBSY for as long as that child lives.
func writeProgram(_ text: String, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o755)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(descriptor) }
    let bytes = Array(text.utf8)
    guard write(descriptor, bytes, bytes.count) == bytes.count else { throw CocoaError(.fileWriteUnknown) }
}
#endif
