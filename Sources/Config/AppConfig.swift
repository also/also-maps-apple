import Foundation

/// A dotted version number, optionally with a build number. Missing components
/// count as zero, so 1.0 and 1.0.0 are the same version.
///
/// `==` and `<` compare the version alone. The build only matters to
/// `isBefore` and `isAfter`, which a range bound uses to reach into a version.
/// In the config file a bound is either a string, `"1.0"`, which covers every
/// build of that version, or an object, `{ "version": "1.0", "build": 42 }`.
struct AppVersion: Comparable, Decodable {
    private let components: [Int]
    let build: Int?

    init?(_ text: String, build: Int? = nil) {
        self.build = build
        let components = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !components.isEmpty, !components.contains(nil) else { return nil }
        self.components = components.compactMap { $0 }
    }

    private enum CodingKeys: String, CodingKey { case version, build }

    init(from decoder: Decoder) throws {
        let text: String
        var build: Int?
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            text = single
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .version)
            build = try c.decodeIfPresent(Int.self, forKey: .build)
        }
        guard let version = AppVersion(text, build: build) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid version: \(text)"))
        }
        self = version
    }

    /// Whether this app is older than `bound`. Against a bound with a build,
    /// the same version is older when its build is lower; an unknown build
    /// counts as the newest.
    func isBefore(_ bound: AppVersion) -> Bool {
        if self != bound { return self < bound }
        guard let boundBuild = bound.build else { return false }
        return (build ?? .max) < boundBuild
    }

    /// Whether this app is newer than `bound`. Against a bound with a build,
    /// the same version is newer when its build is higher; an unknown build
    /// counts as the newest.
    func isAfter(_ bound: AppVersion) -> Bool {
        if self != bound { return self > bound }
        guard let boundBuild = bound.build else { return false }
        return (build ?? .max) > boundBuild
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
        .flatMap { AppVersion($0, build: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)) }
        ?? AppVersion("\(Int.max)")!
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
    /// The lowest and highest app versions this applies to, inclusive. Each is
    /// a version string, or `{ "version": "1.0", "build": 42 }` to reach into
    /// a version's builds.
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
        if let minVersion, version.isBefore(minVersion) { return false }
        if let maxVersion, version.isAfter(maxVersion) { return false }
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
