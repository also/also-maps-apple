import Foundation

/// A GeoJSON file of lines, made fit for cesium-native, which rejects a whole
/// document over one line with fewer than two points (Strava exports have
/// them), and summarised so the camera can go to it.
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

    /// GeoJSON, without the lines cesium-native rejects.
    var data: Data
    var lineCount: Int
    /// A view of where most of the lines are.
    var place: Place

    init(geoJSON: Data, name: String) throws {
        guard let root = try? JSONSerialization.jsonObject(with: geoJSON) as? [String: Any],
              root["type"] is String else { throw Failure.notGeoJSON }
        var lines = LineSummary()
        guard let cleaned = Self.clean(root, &lines), lines.count > 0 else { throw Failure.noLines }
        data = try JSONSerialization.data(withJSONObject: cleaned, options: .withoutEscapingSlashes)
        lineCount = lines.count
        place = lines.place(name: name)
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
            let metresPerDegree = 111_320.0
            let height = spread(latitudes) * metresPerDegree
            let width = spread(longitudes) * metresPerDegree * cos(latitude * .pi / 180)
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
