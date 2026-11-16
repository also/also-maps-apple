import Foundation

/// Places as GeoJSON (RFC 7946), in `.alsomaps` and `.geojson` files. A
/// place is a Point feature, in one of Place's two forms:
///
///     // Where you are: a navigation position, saved to My Map.
///     { "type": "Feature",
///       "geometry": { "type": "Point", "coordinates": [2.2945, 48.8584, 1200] },
///       "properties": { "name": "Over Paris", "alsoMaps": { "heading": 120 } } }
///
///     // What you're looking at: a center and how much to show around it.
///     { "type": "Feature",
///       "geometry": { "type": "Point", "coordinates": [2.2945, 48.8584] },
///       "properties": { "name": "Eiffel Tower", "alsoMaps": { "radius": 400, "heading": 120 } } }
///
/// Coordinates are longitude first. A navigation position has an
/// `alsoMaps` object without `radius`, and its third coordinate is its
/// height in meters above the WGS84 ellipsoid; `alsoMaps.pitch` (degrees)
/// is there when it was saved on a flat screen. Anything else is what
/// you're looking at: `alsoMaps.radius` is the view half-width in meters
/// (a default without it), and a third coordinate is ignored, since other
/// tools use it for the ground's elevation. `alsoMaps.heading` is degrees
/// clockwise from north.
///
/// Reading is tolerant, since files come from anywhere: other geometry,
/// unusable points and unknown members are skipped, not errors. Features'
/// `id`s are ignored and none are written: each place read gets a new id,
/// which only tells places apart while the app runs.
enum PlaceGeoJSON {
    /// View half-width for a point with no usable `alsoMaps.radius`, meters.
    static let defaultRadius = PlaceLink.defaultRadius

    enum ReadError: Error, Equatable {
        case notJSON
        case notGeoJSON
    }

    /// The Point features in a FeatureCollection or a single Feature, in
    /// order, each with a new id.
    static func places(from data: Data) throws -> [Place] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw ReadError.notJSON }
        guard let root = object as? [String: Any] else { throw ReadError.notGeoJSON }
        let features: [Any]
        switch root["type"] as? String {
        case "FeatureCollection": features = root["features"] as? [Any] ?? []
        case "Feature": features = [root]
        default: throw ReadError.notGeoJSON
        }

        return features.compactMap { ($0 as? [String: Any]).flatMap(place(from:)) }
    }

    /// A FeatureCollection of `places`, pretty-printed so it reads and edits
    /// well in a text editor.
    static func data(for places: [Place]) throws -> Data {
        let features: [[String: Any]] = places.map { place in
            var coordinates: [NSDecimalNumber] = [rounded(place.longitude, 7), rounded(place.latitude, 7)]
            var ours: [String: Any] = ["heading": rounded(normalizedHeading(roundedHeading(place.heading)), 2)]
            if let position = place.position {
                coordinates.append(rounded(position.height, 2))
                if let pitch = position.pitch { ours["pitch"] = rounded(pitch, 2) }
            } else {
                ours["radius"] = rounded(place.radius, 1)
            }
            return [
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": coordinates],
                "properties": ["name": place.name, "alsoMaps": ours] as [String: Any],
            ]
        }
        let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        return try JSONSerialization.data(withJSONObject: collection,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// `value` to `places` decimal places, so files read cleanly: 7 for
    /// degrees is about a centimeter. A decimal number, since
    /// JSONSerialization writes a Double's full binary value
    /// (-37.020000000000003); Swift's shortest form doesn't (-37.02).
    private static func rounded(_ value: Double, _ places: Int) -> NSDecimalNumber {
        let scale = pow(10, Double(places))
        var result = (value * scale).rounded() / scale
        if result == 0 { result = 0 }  // No "-0".
        return NSDecimalNumber(string: "\(result)", locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The place for a Point feature, with a new id, or nil for anything
    /// else.
    private static func place(from feature: [String: Any]) -> Place? {
        guard feature["type"] as? String == "Feature",
              let geometry = feature["geometry"] as? [String: Any],
              geometry["type"] as? String == "Point",
              let coordinates = geometry["coordinates"] as? [Any], coordinates.count >= 2,
              let longitude = number(coordinates[0]), (-180...180).contains(longitude),
              let latitude = number(coordinates[1]), (-90...90).contains(latitude)
        else { return nil }
        let properties = feature["properties"] as? [String: Any] ?? [:]
        let ours = properties["alsoMaps"] as? [String: Any]
        let heading = ours?["heading"].flatMap(number).map(normalizedHeading) ?? 0
        let name = (properties["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? PlaceLink.coordinateName(latitude, longitude)
        var place = Place(id: UUID().uuidString, name: name, latitude: latitude, longitude: longitude,
                          radius: defaultRadius, heading: heading)

        if let ours, ours["radius"] == nil, coordinates.count > 2, let height = number(coordinates[2]) {
            // A navigation position. Without its height, it's taken as a
            // center to look at instead.
            let pitch = ours["pitch"].flatMap(number).flatMap { (-90...90).contains($0) ? $0 : nil }
            place.position = Place.Position(height: height, pitch: pitch)
        } else if let radius = ours?["radius"].flatMap(number), radius > 0, radius <= PlaceLink.maximumRadius {
            place.radius = radius
        }
        return place
    }

    /// A finite JSON number. JSONSerialization reads `true` as an NSNumber,
    /// so booleans are rejected.
    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// To 0.01°, so a heading just under 360 becomes 360 and then wraps to 0.
    private static func roundedHeading(_ degrees: Double) -> Double {
        (degrees * 100).rounded() / 100
    }

    private static func normalizedHeading(_ degrees: Double) -> Double {
        let h = degrees.truncatingRemainder(dividingBy: 360)
        return h < 0 ? h + 360 : h
    }
}
