import Foundation
#if canImport(FoundationXML)
import FoundationXML  // XMLParser on Linux; Apple platforms have it in Foundation.
#endif

/// A route as read from a file, before anything is derived from it: the
/// lines it holds (GPX track segments and routes, GeoJSON LineStrings) and
/// each point's position, height, time and sensor values, all as recorded.
struct RouteDocument: Equatable {
    struct Point: Equatable {
        /// Degrees, WGS84.
        var latitude: Double
        var longitude: Double
        /// Metres, measured from `RouteDocument.heightDatum`.
        var height: Double?
        var time: Date?
        /// Beats a minute.
        var heartRate: Double?
        /// Revolutions (or steps, for a run) a minute.
        var cadence: Double?

        init(latitude: Double, longitude: Double, height: Double? = nil, time: Date? = nil,
             heartRate: Double? = nil, cadence: Double? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.height = height
            self.time = time
            self.heartRate = heartRate
            self.cadence = cadence
        }
    }

    /// One unbroken line: drawn joined up, with a gap before the next.
    struct Line: Equatable {
        /// Which GPX track (or GeoJSON feature) the line belongs to, from 0.
        var track: Int
        var points: [Point]
    }

    /// What recorded heights are measured from.
    enum HeightDatum: Equatable {
        /// Mean sea level (the geoid): GPX's `ele`.
        case meanSeaLevel
        /// The WGS84 ellipsoid: GeoJSON's third coordinate, per RFC 7946.
        case ellipsoid
    }

    /// The first name the file gives (the GPX metadata's, or its first
    /// track's or route's), if any.
    var name: String?
    var lines: [Line]
    var heightDatum: HeightDatum

    var pointCount: Int { lines.reduce(0) { $0 + $1.points.count } }
}

enum RouteImportError: LocalizedError, Equatable {
    case unreadable(String)
    case unsupported
    case empty

    var errorDescription: String? {
        switch self {
        case let .unreadable(reason): "The route file couldn't be read: \(reason)"
        case .unsupported: "The file isn't a GPX file or a GeoJSON line."
        case .empty: "The route file has no track or route points."
        }
    }
}

enum RouteImport {
    /// The file extensions offered when opening a route.
    static let fileExtensions = ["gpx", "geojson", "json"]

    /// Reads a GPX or GeoJSON file, chosen by its extension or else by
    /// whether it starts like JSON.
    static func document(from data: Data, fileExtension: String = "") -> Result<RouteDocument, RouteImportError> {
        let ext = fileExtension.lowercased()
        let looksLikeJSON = data.first(where: { !(" \t\r\n" as String).utf8.contains($0) }) == UInt8(ascii: "{")
        let result = ext == "geojson" || ext == "json" || (ext != "gpx" && looksLikeJSON)
            ? GeoJSONRoute.parse(data)
            : GPXParser.parse(data)
        if case let .success(document) = result, document.pointCount == 0 { return .failure(.empty) }
        return result
    }
}

/// GPX 1.0 and 1.1: every track segment (`trk`/`trkseg`/`trkpt`) and route
/// (`rte`/`rtept`) becomes a line; waypoints are ignored. Per point it reads
/// `lat`, `lon`, `ele`, `time`, and heart rate and cadence from the Garmin
/// TrackPointExtension (`gpxtpx:hr`, `gpxtpx:cad`) or the bare `heartrate`
/// and `cadence` some apps write.
///
/// Elements are matched by local name, ignoring their prefix, so an
/// extension whose namespace is undeclared or bound to another prefix (ns3:
/// is common) still reads. Namespace processing stays off for that reason:
/// with it on, an undeclared prefix is an error.
final class GPXParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) -> Result<RouteDocument, RouteImportError> {
        let delegate = GPXParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "not well-formed XML"
            return .failure(.unreadable(reason))
        }
        guard delegate.sawRoot else { return .failure(.unsupported) }
        return .success(RouteDocument(name: delegate.name, lines: delegate.lines, heightDatum: .meanSeaLevel))
    }

    private var sawRoot = false
    private var name: String?
    private var lines: [RouteDocument.Line] = []
    /// Local names of the open elements, outermost first.
    private var path: [String] = []
    private var text = ""
    private var track = -1
    private var line: [RouteDocument.Point]?
    private var point: RouteDocument.Point?

    private let timeFormats: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    private static func localName(_ qualified: String) -> String {
        qualified.split(separator: ":").last.map { String($0).lowercased() } ?? ""
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let element = Self.localName(elementName)
        if path.isEmpty, element == "gpx" { sawRoot = true }
        path.append(element)
        text = ""
        switch element {
        case "trk":
            track += 1
        case "rte":
            track += 1
            line = []
        case "trkseg":
            line = []
        case "trkpt", "rtept":
            // Points outside a segment, or with no usable position, are skipped.
            guard line != nil,
                  let latitude = attributes["lat"].flatMap(Self.number),
                  let longitude = attributes["lon"].flatMap(Self.number),
                  (-90...90).contains(latitude), (-180...180).contains(longitude)
            else { point = nil; return }
            point = RouteDocument.Point(latitude: latitude, longitude: longitude)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let element = Self.localName(elementName)
        defer {
            path.removeLast()
            text = ""
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if point != nil {
            switch element {
            case "ele": point?.height = Self.number(value)
            case "time": point?.time = time(value)
            case "hr", "heartrate": point?.heartRate = Self.number(value)
            case "cad", "cadence": point?.cadence = Self.number(value)
            default: break
            }
        }
        switch element {
        case "trkpt", "rtept":
            if let point { line?.append(point) }
            point = nil
        case "trkseg", "rte":
            if let points = line, !points.isEmpty {
                lines.append(RouteDocument.Line(track: max(track, 0), points: points))
            }
            line = nil
        case "name":
            // The file's own name, or its first track's or route's.
            let parent = path.dropLast().last
            if name == nil, !value.isEmpty, parent == "metadata" || parent == "trk" || parent == "rte"
                || (parent == "gpx" && path.count == 2) {
                name = value
            }
        default:
            break
        }
    }

    private func time(_ text: String) -> Date? {
        for format in timeFormats {
            if let date = format.date(from: text) { return date }
        }
        return nil
    }

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isFinite ? $0 : nil }
    }
}

/// GeoJSON (RFC 7946): every LineString becomes a line and each
/// MultiLineString several, from a bare geometry, a Feature, a
/// FeatureCollection or a GeometryCollection. Coordinates are
/// [longitude, latitude, height?], the height above the ellipsoid as the
/// RFC says (though some tools write sea level there).
///
/// Times and heart rates aren't part of GeoJSON. The two conventions
/// togeojson writes from GPX are read when present: a Feature's
/// `properties.coordTimes`, or `properties.coordinateProperties.times` and
/// `.heart`, one entry per coordinate (nested per line for a
/// MultiLineString).
enum GeoJSONRoute {
    static func parse(_ data: Data) -> Result<RouteDocument, RouteImportError> {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        guard let object = json as? [String: Any], object["type"] is String else { return .failure(.unsupported) }
        var document = RouteDocument(name: nil, lines: [], heightDatum: .ellipsoid)
        var track = 0
        // GeoJSON with no lines (only points, say) reads as an empty route.
        collect(object, properties: nil, into: &document, track: &track)
        return .success(document)
    }

    private static func collect(_ object: [String: Any], properties: [String: Any]?,
                                into document: inout RouteDocument, track: inout Int) {
        switch object["type"] as? String {
        case "FeatureCollection":
            for case let feature as [String: Any] in object["features"] as? [Any] ?? [] {
                collect(feature, properties: nil, into: &document, track: &track)
            }
        case "Feature":
            let properties = object["properties"] as? [String: Any]
            if document.name == nil, let name = properties?["name"] as? String, !name.isEmpty {
                document.name = name
            }
            if let geometry = object["geometry"] as? [String: Any] {
                collect(geometry, properties: properties, into: &document, track: &track)
            }
        case "GeometryCollection":
            for case let geometry as [String: Any] in object["geometries"] as? [Any] ?? [] {
                collect(geometry, properties: nil, into: &document, track: &track)
            }
        case "LineString":
            let line = points(object["coordinates"], times: perCoordinate(properties, "times", line: nil),
                              hearts: perCoordinate(properties, "heart", line: nil))
            if !line.isEmpty {
                document.lines.append(RouteDocument.Line(track: track, points: line))
                track += 1
            }
        case "MultiLineString":
            let before = document.lines.count
            for (i, coordinates) in (object["coordinates"] as? [Any] ?? []).enumerated() {
                let line = points(coordinates, times: perCoordinate(properties, "times", line: i),
                                  hearts: perCoordinate(properties, "heart", line: i))
                if !line.isEmpty { document.lines.append(RouteDocument.Line(track: track, points: line)) }
            }
            if document.lines.count > before { track += 1 }
        default:
            break  // Points and polygons aren't routes.
        }
    }

    /// togeojson's per-coordinate arrays: `coordinateProperties[key]`, or for
    /// times the older `coordTimes`; for a MultiLineString, the `line`th.
    private static func perCoordinate(_ properties: [String: Any]?, _ key: String, line: Int?) -> [Any]? {
        let coordinateProperties = properties?["coordinateProperties"] as? [String: Any]
        var values = coordinateProperties?[key] as? [Any]
        if values == nil, key == "times" { values = properties?["coordTimes"] as? [Any] }
        guard let values else { return nil }
        guard let line else { return values }
        return line < values.count ? values[line] as? [Any] : nil
    }

    private static let timeFormats: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    private static func points(_ coordinates: Any?, times: [Any]?, hearts: [Any]?) -> [RouteDocument.Point] {
        guard let coordinates = coordinates as? [Any] else { return [] }
        var points: [RouteDocument.Point] = []
        for (i, entry) in coordinates.enumerated() {
            guard let position = entry as? [Any], position.count >= 2,
                  let longitude = number(position[0]), let latitude = number(position[1]),
                  (-90...90).contains(latitude), (-180...180).contains(longitude)
            else { continue }
            var point = RouteDocument.Point(latitude: latitude, longitude: longitude,
                                            height: position.count > 2 ? number(position[2]) : nil)
            if let times, i < times.count, let text = times[i] as? String {
                point.time = timeFormats.lazy.compactMap { $0.date(from: text) }.first
            }
            if let hearts, i < hearts.count { point.heartRate = number(hearts[i]) }
            points.append(point)
        }
        return points
    }

    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        // JSON true/false come through as NSNumber too.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}
