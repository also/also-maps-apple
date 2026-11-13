import Foundation

/// Links that open the app at a place, for "Open in Also Maps" buttons:
///
///     https://maps.also.dev/p#lat=48.8584&lon=2.2945&r=400&h=120
///     alsomaps://p#lat=48.8584&lon=2.2945&r=400&h=120
///
/// The universal link and the custom scheme carry the same fragment, so one
/// parser reads both. The site's `/p` fallback page reads the same format;
/// keep the two in step.
///
/// The fragment is form-encoded. `lat` and `lon` (decimal degrees) are
/// required. `r` (view half-width, meters: `Place.radius`) and `h` (degrees
/// clockwise from north: `Place.heading`) are optional, and an unusable value
/// counts as absent. Unknown keys are ignored. The scheme and host are
/// ignored; the path must be `/p`.
///
/// Links carry no text: a crafted link mustn't control what the app shows.
/// The place is named by its coordinates.
enum PlaceLink {
    /// View half-width when a link has no `r`, meters.
    static let defaultRadius = 500.0
    /// Larger than this, and the framing camera ends up past the screen
    /// map's highest altitude.
    static let maximumRadius = 10_000_000.0

    /// The place a link points at, with a new id, or nil if it isn't a
    /// usable place link.
    static func place(from url: URL) -> Place? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              isPlacePath(components),
              let fragment = components.percentEncodedFragment else { return nil }
        let fields = formFields(fragment)

        guard let latitude = fields["lat"].flatMap(number), (-90...90).contains(latitude),
              let longitude = fields["lon"].flatMap(number), (-180...180).contains(longitude)
        else { return nil }

        let radius = fields["r"].flatMap(number).flatMap { $0 > 0 && $0 <= maximumRadius ? $0 : nil }
            ?? defaultRadius
        let heading = fields["h"].flatMap(number).map(normalizedHeading) ?? 0
        return Place(id: "link-\(UUID().uuidString)", name: coordinateName(latitude, longitude),
                     latitude: latitude, longitude: longitude, radius: radius, heading: heading)
    }

    /// `/p` on the web; in `alsomaps://p`, `p` is the host and the path is
    /// empty, so take the host as the first segment there.
    private static func isPlacePath(_ components: URLComponents) -> Bool {
        let path = components.percentEncodedPath
        if path == "" || path == "/" { return components.percentEncodedHost == "p" }
        return path == "/p" || path == "/p/"
    }

    /// `application/x-www-form-urlencoded` pairs: `+` is a space, then
    /// percent-decoded. The first occurrence of a key wins.
    private static func formFields(_ fragment: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String? {
                s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            }
            guard let key = decode(parts[0]),
                  let value = parts.count > 1 ? decode(parts[1]) : "" else { continue }
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }

    /// A finite decimal number. `Double("nan")` and `Double("inf")` parse, so
    /// they're rejected here.
    private static func number(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else { return nil }
        return value
    }

    private static func normalizedHeading(_ degrees: Double) -> Double {
        let h = degrees.truncatingRemainder(dividingBy: 360)
        return h < 0 ? h + 360 : h
    }

    private static func coordinateName(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }
}
