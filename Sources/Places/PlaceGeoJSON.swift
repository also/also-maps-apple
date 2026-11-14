import Foundation

/// Places as GeoJSON (RFC 7946), the format of `.alsomaps` and `.geojson`
/// place files:
///
///     {
///       "type": "FeatureCollection",
///       "features": [{
///         "type": "Feature",
///         "id": "…",
///         "geometry": { "type": "Point", "coordinates": [2.2945, 48.8584, 35] },
///         "properties": {
///           "name": "Eiffel Tower",
///           "alsoMaps": { "radius": 400, "heading": 120 }
///         }
///       }]
///     }
///
/// A place is a Point feature. Its coordinates are the view center,
/// longitude first, with an optional height in meters above the WGS84
/// ellipsoid. `alsoMaps.radius` is the view half-width in meters and
/// `alsoMaps.heading` the direction the view faces, degrees clockwise from
/// north; both are optional.
///
/// Reading is tolerant, since files come from anywhere: other geometry,
/// unusable points and unknown members are skipped, not errors.
enum PlaceGeoJSON {
    /// View half-width for a point with no usable `alsoMaps.radius`, meters.
    static let defaultRadius = PlaceLink.defaultRadius

    enum ReadError: Error, Equatable {
        case notJSON
        case notGeoJSON
    }

    /// The Point features in a FeatureCollection or a single Feature, in
    /// order. Each place's id is the feature's `id` prefixed with
    /// `idPrefix`, or its position when the feature has none or repeats one.
    static func places(from data: Data, idPrefix: String = "") throws -> [Place] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw ReadError.notJSON }
        guard let root = object as? [String: Any] else { throw ReadError.notGeoJSON }
        let features: [Any]
        switch root["type"] as? String {
        case "FeatureCollection": features = root["features"] as? [Any] ?? []
        case "Feature": features = [root]
        default: throw ReadError.notGeoJSON
        }

        var places: [Place] = []
        var seen = Set<String>()
        for (index, item) in features.enumerated() {
            guard let feature = item as? [String: Any], var place = place(from: feature) else { continue }
            var id = featureID(feature["id"]) ?? "#\(index)"
            if seen.contains(id) { id = "#\(index)" }
            seen.insert(id)
            place = Place(id: idPrefix + id, name: place.name, latitude: place.latitude,
                          longitude: place.longitude, radius: place.radius, heading: place.heading,
                          altitude: place.altitude)
            places.append(place)
        }
        return places
    }

    /// A FeatureCollection of `places`, pretty-printed so it reads and edits
    /// well in a text editor.
    static func data(for places: [Place]) throws -> Data {
        let features: [[String: Any]] = places.map { place in
            var coordinates: [NSDecimalNumber] = [rounded(place.longitude, 7), rounded(place.latitude, 7)]
            if let altitude = place.altitude { coordinates.append(rounded(altitude, 2)) }
            return [
                "type": "Feature",
                "id": place.id,
                "geometry": ["type": "Point", "coordinates": coordinates],
                "properties": [
                    "name": place.name,
                    "alsoMaps": ["radius": rounded(place.radius, 1),
                                 "heading": rounded(normalizedHeading(roundedHeading(place.heading)), 2)],
                ] as [String: Any],
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

    /// The place for a Point feature, with an empty id, or nil for anything
    /// else.
    private static func place(from feature: [String: Any]) -> Place? {
        guard feature["type"] as? String == "Feature",
              let geometry = feature["geometry"] as? [String: Any],
              geometry["type"] as? String == "Point",
              let coordinates = geometry["coordinates"] as? [Any], coordinates.count >= 2,
              let longitude = number(coordinates[0]), (-180...180).contains(longitude),
              let latitude = number(coordinates[1]), (-90...90).contains(latitude)
        else { return nil }
        let altitude = coordinates.count > 2 ? number(coordinates[2]) : nil

        let properties = feature["properties"] as? [String: Any] ?? [:]
        let ours = properties["alsoMaps"] as? [String: Any] ?? [:]
        let radius = ours["radius"].flatMap(number).flatMap { $0 > 0 && $0 <= PlaceLink.maximumRadius ? $0 : nil }
            ?? defaultRadius
        let heading = ours["heading"].flatMap(number).map(normalizedHeading) ?? 0
        let name = (properties["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? PlaceLink.coordinateName(latitude, longitude)
        return Place(id: "", name: name, latitude: latitude, longitude: longitude,
                     radius: radius, heading: heading, altitude: altitude)
    }

    /// GeoJSON allows a string or a number.
    private static func featureID(_ value: Any?) -> String? {
        switch value {
        case let string as String where !string.isEmpty: return string
        case let number as NSNumber where !(number is Bool) && CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.stringValue
        default: return nil
        }
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
