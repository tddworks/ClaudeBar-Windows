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
