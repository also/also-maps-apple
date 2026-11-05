import Foundation

/// The hand-written route files in Fixtures/, read from the source tree
/// (they aren't copied into the test bundle).
enum RouteFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func document(_ name: String) throws -> RouteDocument {
        let url = directory.appendingPathComponent(name)
        return try RouteImport.document(from: try Data(contentsOf: url), fileExtension: url.pathExtension).get()
    }
}

/// An ISO 8601 time, for expectations.
func routeTime(_ text: String) -> Date {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = format.date(from: text) { return date }
    format.formatOptions = [.withInternetDateTime]
    return format.date(from: text)!
}
