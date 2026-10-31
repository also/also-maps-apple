import Foundation

/// A dotted version number. Missing components count as zero, so 1.0 and
/// 1.0.0 are the same version.
struct AppVersion: Comparable, Decodable {
    private let components: [Int]

    init?(_ text: String) {
        let components = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !components.isEmpty, !components.contains(nil) else { return nil }
        self.components = components.compactMap { $0 }
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = AppVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid version: \(text)"))
        }
        self = version
    }

    private func comparisonKey(length: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, length - components.count))
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let length = max(lhs.components.count, rhs.components.count)
        return lhs.comparisonKey(length: length) == rhs.comparisonKey(length: length)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let length = max(lhs.components.count, rhs.components.count)
        return lhs.comparisonKey(length: length).lexicographicallyPrecedes(rhs.comparisonKey(length: length))
    }

    /// The running app. An unreadable version counts as the newest possible,
    /// so "older than" rules can't block it by mistake.
    static let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        .flatMap(AppVersion.init) ?? AppVersion("\(Int.max)")!
}

/// A message from the remote config. A `blocking` notice replaces the app, and
/// is how the kill switch and minimum version work: a kill switch has no
/// version range, and a minimum version has a `maxVersion`.
struct Notice: Decodable, Identifiable, Equatable {
    enum Severity: String, Decodable {
        /// Shown once, then dismissed for good.
        case info
        /// Stops the app while it applies.
        case blocking
    }

    struct Link: Decodable, Equatable {
        let title: String
        let url: URL
    }

    let id: String
    let severity: Severity
    let title: String
    let body: String
    var link: Link?
    /// Platforms this applies to; nil is all of them. See `AppPlatform`.
    var platforms: [String]?
    /// The lowest and highest app versions this applies to, inclusive.
    var minVersion: AppVersion?
    var maxVersion: AppVersion?
    /// "app" or "own": who's using which key. Limits a notice about the shared
    /// key, so people with their own keep going.
    var keySource: String?
    /// When this stops applying, even if the file is never updated.
    var expires: Date?

    func applies(platform: String, version: AppVersion, keySource: String, now: Date) -> Bool {
        if let platforms, !platforms.contains(platform) { return false }
        if let source = self.keySource, source != keySource { return false }
        if let minVersion, version < minVersion { return false }
        if let maxVersion, version > maxVersion { return false }
        if let expires, now >= expires { return false }
        return true
    }
}

enum AppPlatform {
    static var current: String {
        #if os(visionOS)
        "visionos"
        #elseif os(tvOS)
        "tvos"
        #elseif os(iOS)
        "ios"
        #else
        "macos"
        #endif
    }
}

/// The remote config file. Entries this build can't understand are skipped
/// rather than failing the file, so a new field, severity or place in the file
/// can't break apps already released. Targeting a notice with a new field is
/// the exception: older builds ignore the field and show it more widely.
struct AppConfig: Decodable {
    let notices: [Notice]
    /// Replaces the bundled places. Nil if the file has none that are usable.
    let places: [Place]?
    /// False turns off the app's shared key, leaving people's own.
    let appKeysEnabled: Bool

    private enum CodingKeys: String, CodingKey { case notices, places, appKeys }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) { value = try? Value(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notices = try (c.decodeIfPresent([Lossy<Notice>].self, forKey: .notices) ?? []).compactMap(\.value)
        var seen = Set<String>()
        let places = try (c.decodeIfPresent([Lossy<Place>].self, forKey: .places) ?? [])
            .compactMap(\.value)
            .filter { $0.isValid && seen.insert($0.id).inserted }
        self.places = places.isEmpty ? nil : places
        appKeysEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .appKeys)) ?? true
    }

    static func decode(_ data: Data) throws -> AppConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppConfig.self, from: data)
    }
}

private extension Place {
    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude) && radius > 0
    }
}
