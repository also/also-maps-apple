import Foundation

/// A GeoJSON file of lines, made fit for cesium-native, which rejects a whole
/// document over one line with fewer than two points (Strava exports have
/// them), and summarized so the camera can go to it.
struct TraceFile {
    enum Failure: LocalizedError {
        case notGeoJSON
        case noLines

        var errorDescription: String? {
            switch self {
            case .notGeoJSON: "This isn't a GeoJSON file."
            case .noLines: "This file has no lines to draw."
            }
        }
    }

    /// A JSON array of GeoJSON Features, without the lines cesium-native
    /// rejects, for joining with other files' (`collection`).
    var features: Data
    var lineCount: Int
    /// A view of where most of the lines are.
    var place: Place

    init(geoJSON: Data, name: String) throws {
        guard let root = try? JSONSerialization.jsonObject(with: geoJSON) as? [String: Any],
              root["type"] is String else { throw Failure.notGeoJSON }
        try self.init(root: root, name: name)
    }

    /// Lines of longitude–latitude pairs, from another format.
    init(lines: [[[Double]]], name: String) throws {
        try self.init(root: ["type": "MultiLineString", "coordinates": lines], name: name)
    }

    private init(root: [String: Any], name: String) throws {
        var lines = LineSummary()
        guard let cleaned = Self.clean(root, &lines), lines.count > 0 else { throw Failure.noLines }
        features = try JSONSerialization.data(withJSONObject: Self.features(of: cleaned),
                                              options: .withoutEscapingSlashes)
        lineCount = lines.count
        place = lines.place(name: name)
    }

    /// One FeatureCollection of several files' `features`, joined as text so
    /// that even large files join quickly.
    static func collection(_ featureArrays: [Data]) -> Data {
        var data = Data(#"{"type":"FeatureCollection","features":["#.utf8)
        var first = true
        for array in featureArrays {
            // Between the brackets, without surrounding whitespace.
            guard let open = array.firstIndex(of: UInt8(ascii: "[")),
                  let close = array.lastIndex(of: UInt8(ascii: "]")), close > open + 1 else { continue }
            let inner = array[(open + 1)..<close]
            guard inner.contains(where: { !Character(UnicodeScalar($0)).isWhitespace }) else { continue }
            if !first { data.append(UInt8(ascii: ",")) }
            data.append(contentsOf: inner)
            first = false
        }
        data.append(contentsOf: Data("]}".utf8))
        return data
    }

    /// The Features an object holds: a collection's own, a Feature, or a
    /// bare geometry wrapped in one.
    private static func features(of object: [String: Any]) -> [[String: Any]] {
        switch object["type"] as? String {
        case "FeatureCollection": object["features"] as? [[String: Any]] ?? []
        case "Feature": [object]
        default: [["type": "Feature", "properties": [String: Any](), "geometry": object]]
        }
    }

    /// Where each line's middle is. Medians, so that one trip abroad doesn't
    /// leave the view over the ocean between it and all the others.
    private struct LineSummary {
        var count = 0
        var latitudes: [Double] = []
        var longitudes: [Double] = []

        mutating func add(_ line: [Any]) {
            count += 1
            if let middle = line[line.count / 2] as? [Double], middle.count >= 2 {
                longitudes.append(middle[0])
                latitudes.append(middle[1])
            }
        }

        func place(name: String) -> Place {
            let latitudes = latitudes.sorted()
            let longitudes = longitudes.sorted()
            func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values[values.count / 2] }
            func spread(_ values: [Double]) -> Double {
                values.isEmpty ? 0 : values[values.count * 3 / 4] - values[values.count / 4]
            }
            let latitude = median(latitudes)
            let metersPerDegree = 111_320.0
            let height = spread(latitudes) * metersPerDegree
            let width = spread(longitudes) * metersPerDegree * cos(latitude * .pi / 180)
            return Place(id: "traces", name: name, latitude: latitude, longitude: median(longitudes),
                         radius: min(max(max(width, height) / 2, 500), 50_000))
        }
    }

    /// The object without short lines, or nil if that leaves nothing of it.
    private static func clean(_ object: [String: Any], _ lines: inout LineSummary) -> [String: Any]? {
        var object = object
        switch object["type"] as? String {
        case "FeatureCollection":
            let features = object["features"] as? [[String: Any]] ?? []
            object["features"] = features.compactMap { clean($0, &lines) }
        case "GeometryCollection":
            let geometries = object["geometries"] as? [[String: Any]] ?? []
            let kept = geometries.compactMap { clean($0, &lines) }
            guard !kept.isEmpty else { return nil }
            object["geometries"] = kept
        case "Feature":
            // A feature with no geometry has nothing to draw.
            guard let geometry = object["geometry"] as? [String: Any],
                  let kept = clean(geometry, &lines) else { return nil }
            object["geometry"] = kept
        case "LineString":
            guard let line = object["coordinates"] as? [Any], line.count >= 2 else { return nil }
            lines.add(line)
        case "MultiLineString":
            let parts = object["coordinates"] as? [[Any]] ?? []
            let kept = parts.filter { $0.count >= 2 }
            guard !kept.isEmpty else { return nil }
            kept.forEach { lines.add($0) }
            object["coordinates"] = kept
        default:
            break
        }
        return object
    }
}
