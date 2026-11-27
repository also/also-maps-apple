import Foundation

/// The lines in a KML file: `LineString`s and `gx:Track`s, wherever they are
/// (Placemarks, MultiGeometry, gx:MultiTrack, Folders). Points and polygons
/// are skipped.
///
/// Lines are either on the ground or in the air. Only `absolute` lines with
/// some altitude other than zero are in the air: those become a Track, drawn
/// as a tube and flown along. Everything else, including `clampToGround`
/// (KML's default) and `relativeToGround`, has no height the map can use
/// without sampling the ground, so it's draped like GeoJSON traces.
///
/// KML's absolute altitudes are above mean sea level; they're used as
/// heights above the WGS84 ellipsoid, which the map uses. The difference
/// (the geoid) is within about ±100 m, and around −30 m in much of the US,
/// so tracks are drawn that much too high there.
struct KMLFile {
    enum Failure: LocalizedError {
        case notKML
        case noLines

        var errorDescription: String? {
            switch self {
            case .notKML: "This isn't a KML file."
            case .noLines: "This file has no lines to draw."
            }
        }
    }

    struct Coordinate: Equatable {
        var longitude: Double
        var latitude: Double
        /// Meters; 0 when the file gives none.
        var altitude: Double
    }

    struct Line {
        /// The Placemark's name, if it has one.
        var name: String?
        var coordinates: [Coordinate]
        /// One per coordinate, for a gx:Track with all its `when`s.
        var times: [Date]?
        var altitudeMode: String

        var isAirborne: Bool {
            altitudeMode == "absolute" && coordinates.contains { $0.altitude != 0 }
        }
    }

    var lines: [Line]

    init(data: Data) throws {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.sawKML else { throw Failure.notKML }
        lines = reader.lines.filter { $0.coordinates.count >= 2 }
        guard !lines.isEmpty else { throw Failure.noLines }
    }

    /// The lines on the ground, as longitude–latitude pairs for draping.
    var groundLines: [[[Double]]] {
        lines.filter { !$0.isAirborne }.map { line in
            line.coordinates.map { [$0.longitude, $0.latitude] }
        }
    }

    // MARK: Tracks

    /// Playback never takes longer than this: longer tracks are sped up.
    static let longestPlayback: TimeInterval = 300
    /// The speed for lines without times, meters a second.
    static let speedWithoutTimes = 50.0
    /// Gaps between lines are cut to this, seconds.
    static let gapBetweenLines: TimeInterval = 1
    /// How far either side of a fix its heading is measured over, meters,
    /// so GPS jitter doesn't swing the camera.
    static let headingBaseline = 20.0
    static let viewpoint = Track.Viewpoint.behind(distance: 100, height: 30)

    /// The lines in the air as one track, a segment per line, or nil if
    /// there are none. Lines keep their own times when they all have them,
    /// and are put in time order; otherwise they're flown in file order at
    /// `speedWithoutTimes`.
    func track(name: String) -> Track? {
        var airborne = lines.filter(\.isAirborne)
        guard !airborne.isEmpty else { return nil }
        let timed = airborne.allSatisfy { $0.times != nil }
        if timed { airborne.sort { $0.times![0] < $1.times![0] } }

        var samples: [Track.Sample] = []
        var clock: TimeInterval = 0
        for (segment, line) in airborne.enumerated() {
            let offsets = timed
                ? line.times!.map { $0.timeIntervalSince(line.times![0]) }
                : Self.offsetsAtSpeed(line.coordinates)
            let headings = Self.headings(line.coordinates)
            if segment > 0 { clock += Self.gapBetweenLines }
            for (i, coordinate) in line.coordinates.enumerated() {
                let pose = CameraPose(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                      height: coordinate.altitude, heading: headings[i], pitch: 0)
                samples.append(Track.Sample(time: Date(timeIntervalSinceReferenceDate: clock + offsets[i]),
                                            segment: segment, pose: pose))
            }
            clock += offsets.last ?? 0
        }

        if clock > Self.longestPlayback {
            let rate = Self.longestPlayback / clock
            for i in samples.indices {
                samples[i].time = Date(timeIntervalSinceReferenceDate:
                                        samples[i].time.timeIntervalSinceReferenceDate * rate)
            }
        }
        return Track(name: name, samples: samples, viewpoint: Self.viewpoint)
    }

    /// Seconds from the first coordinate to each, at `speedWithoutTimes`.
    static func offsetsAtSpeed(_ coordinates: [Coordinate]) -> [TimeInterval] {
        var offsets = [0.0]
        for i in coordinates.indices.dropFirst() {
            offsets.append(offsets[i - 1] + distance(coordinates[i - 1], coordinates[i]) / speedWithoutTimes)
        }
        return offsets
    }

    /// Each coordinate's direction of travel, radians clockwise from north:
    /// the bearing from `headingBaseline` meters before it to as far after,
    /// or as near as the line's ends allow. A line that never moves that far
    /// faces north.
    static func headings(_ coordinates: [Coordinate]) -> [Double] {
        var headings: [Double] = []
        for i in coordinates.indices {
            var before = i
            while before > 0, distance(coordinates[before], coordinates[i]) < headingBaseline { before -= 1 }
            var after = i
            while after < coordinates.count - 1, distance(coordinates[i], coordinates[after]) < headingBaseline {
                after += 1
            }
            let from = coordinates[before], to = coordinates[after]
            if distance(from, to) < 1 {
                headings.append(headings.last ?? 0)
            } else {
                headings.append(bearing(from, to))
            }
        }
        return headings
    }

    /// Ground distance in meters, flat-earth, which is fine over a few
    /// kilometers.
    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let (north, east) = offset(a, b)
        return (north * north + east * east).squareRoot()
    }

    /// Radians clockwise from north, from `a` to `b`.
    static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let (north, east) = offset(a, b)
        let angle = atan2(east, north)
        return angle < 0 ? angle + 2 * .pi : angle
    }

    private static func offset(_ a: Coordinate, _ b: Coordinate) -> (north: Double, east: Double) {
        let metersPerDegree = 111_320.0
        let latitude = (a.latitude + b.latitude) / 2 * .pi / 180
        return ((b.latitude - a.latitude) * metersPerDegree,
                remainder(b.longitude - a.longitude, 360) * metersPerDegree * cos(latitude))
    }

    // MARK: Reading

    private final class Reader: NSObject, XMLParserDelegate {
        var lines: [Line] = []
        var sawKML = false

        /// Open elements' local names.
        private var path: [String] = []
        private var text = ""
        private var placemarkName: String?
        /// The line being read, and the altitude mode of an enclosing
        /// gx:MultiTrack, which its tracks inherit.
        private var line: Line?
        private var multiTrackMode: String?

        private static let defaultMode = "clampToGround"

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = Self.localName(elementName)
            path.append(name)
            text = ""
            switch name {
            case "kml": sawKML = true
            case "Placemark": placemarkName = nil
            case "MultiTrack": multiTrackMode = nil
            case "LineString":
                line = Line(name: placemarkName, coordinates: [], times: nil, altitudeMode: Self.defaultMode)
            case "Track":
                line = Line(name: placemarkName, coordinates: [], times: [],
                            altitudeMode: multiTrackMode ?? Self.defaultMode)
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let name = Self.localName(elementName)
            let parent = path.count >= 2 ? path[path.count - 2] : nil
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "name" where parent == "Placemark":
                placemarkName = value
                line?.name = value
            case "altitudeMode" where parent == "LineString" || parent == "Track":
                line?.altitudeMode = value
            case "altitudeMode" where parent == "MultiTrack":
                multiTrackMode = value
            case "coordinates" where parent == "LineString":
                line?.coordinates = Self.coordinates(value)
            case "coord" where parent == "Track":
                if let coordinate = Self.trackCoordinate(value) { line?.coordinates.append(coordinate) }
            case "when" where parent == "Track":
                if let time = Self.time(value) { line?.times?.append(time) } else { line?.times = nil }
            case "LineString", "Track":
                if var line {
                    if line.times?.count != line.coordinates.count { line.times = nil }
                    lines.append(line)
                }
                line = nil
            default: break
            }
            path.removeLast()
            text = ""
        }

        static func localName(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        /// "lon,lat[,alt] lon,lat[,alt] …"
        static func coordinates(_ text: String) -> [Coordinate] {
            text.split(whereSeparator: \.isWhitespace).compactMap { tuple in
                let parts = tuple.split(separator: ",").compactMap { Double($0) }
                guard parts.count >= 2 else { return nil }
                return Coordinate(longitude: parts[0], latitude: parts[1], altitude: parts.count > 2 ? parts[2] : 0)
            }
        }

        /// gx:coord: "lon lat [alt]"
        static func trackCoordinate(_ text: String) -> Coordinate? {
            let parts = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            guard parts.count >= 2 else { return nil }
            return Coordinate(longitude: parts[0], latitude: parts[1], altitude: parts.count > 2 ? parts[2] : 0)
        }

        static func time(_ text: String) -> Date? {
            (try? fractionalTime.parse(text)) ?? (try? wholeTime.parse(text))
        }

        // Format styles parse about 100 times faster than ISO8601DateFormatter.
        private static let fractionalTime = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        private static let wholeTime = Date.ISO8601FormatStyle()
    }
}
