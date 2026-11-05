import Foundation
import simd

/// Where an imported route's heights come from.
enum RouteHeightMode: String, CaseIterable, Identifiable {
    /// On the map's surface, sampled while the app runs and lifted a little
    /// above it: GPS heights are too noisy to keep a run or a ride on the
    /// ground.
    case ground
    /// The file's own heights, sea-level ones moved onto the ellipsoid with
    /// the geoid: for flights, or to see the recording as it was.
    case recorded

    var id: Self { self }

    var name: String {
        switch self {
        case .ground: "On the ground"
        case .recorded: "As recorded"
        }
    }
}

/// A route read from a file, ready to draw and replay: its points in
/// segments (a gap between each), with what's derived from them: distance
/// along the route, smoothed speed, and the replay clock.
///
/// Heights aren't fixed here: `heights(mode:surface:)` chooses them, from
/// the file or from the map's surface, which the caller samples while the
/// app runs and must not store (Google's terms; README).
struct ImportedRoute {
    struct Point: Equatable {
        var coordinate: GeoCoordinate
        var segment: Int
        /// Metres above the ellipsoid, from the file, if it had a height.
        var recordedHeight: Double?
        /// Metres above mean sea level, for colouring, if the file had a height.
        var elevation: Double?
        var time: Date?
        var heartRate: Double?
        var cadence: Double?
        /// Metres along the route from its first point, not counting the
        /// gaps between segments.
        var distance: Double = 0
        /// Metres a second, over `speedWindow`; nil without times.
        var speed: Double?
        /// Seconds into the replay: the recorded times with pauses cut
        /// short, or, without times, the distance at `nominalSpeed`.
        var replayTime: Double = 0
    }

    let name: String
    let points: [Point]
    /// Each segment's range of `points`, in order, none empty.
    let segments: [Range<Int>]
    /// Every point has a time, in order, so speed and the replay follow the
    /// recording.
    let hasTimes: Bool
    /// Metres a second while moving, for choosing how far back to chase.
    let typicalSpeed: Double

    var length: Double { points.last?.distance ?? 0 }
    var replayDuration: Double { points.last?.replayTime ?? 0 }

    /// Speed is distance over this many seconds centred on each point, so a
    /// GPS fix that jumps a few metres doesn't spike it.
    static let speedWindow = 10.0
    /// A gap between fixes longer than this, covering less than
    /// `pauseSpeed`, is a pause (a café, a traffic light, a watch's
    /// auto-pause), and the replay skips it in a second.
    static let pauseThreshold = 10.0
    static let pauseSpeed = 0.5
    /// The replay's speed for a route with no times (a planned route).
    static let nominalSpeed = 10.0
    /// Points are added so no step is longer than this, metres, so a
    /// sparse route (a planned one, or a watch recording every 30 s) still
    /// follows the ground between its points when draped.
    static let maximumStep = 30.0
    /// The most points densifying may make; above it, steps get longer.
    static let maximumPoints = 50_000
    /// How far above the sampled surface a draped route runs, metres. The
    /// overlay also lifts the tube by its own radius, so it sits on top.
    static let groundClearance = 1.0

    /// Nil if the document has no points.
    init?(document: RouteDocument, fallbackName: String = "Route") {
        var raw: [Point] = []
        var segments: [Range<Int>] = []
        for line in document.lines {
            let start = raw.count
            for p in line.points {
                let geoid = Geoid.height(latitude: p.latitude, longitude: p.longitude)
                let recorded: Double?, elevation: Double?
                switch document.heightDatum {
                case .meanSeaLevel:
                    recorded = p.height.map { $0 + geoid }
                    elevation = p.height
                case .ellipsoid:
                    recorded = p.height
                    elevation = p.height.map { $0 - geoid }
                }
                raw.append(Point(coordinate: GeoCoordinate(latitude: p.latitude, longitude: p.longitude),
                                 segment: segments.count, recordedHeight: recorded, elevation: elevation,
                                 time: p.time, heartRate: p.heartRate, cadence: p.cadence))
            }
            if raw.count > start { segments.append(start..<raw.count) }
        }
        guard !raw.isEmpty else { return nil }

        let times = raw.compactMap(\.time)
        let timed = times.count == raw.count && zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }
        if !timed {
            for i in raw.indices { raw[i].time = nil }
        }

        let length = Self.measure(&raw, segments: segments)
        let step = max(Self.maximumStep, length / Double(Self.maximumPoints))
        var points: [Point] = []
        (points, segments) = Self.densified(raw, segments: segments, maximumStep: step)
        _ = Self.measure(&points, segments: segments)
        if timed { Self.measureSpeed(&points, segments: segments) }
        let moving = Self.assignReplayTimes(&points, segments: segments, hasTimes: timed)

        name = document.name ?? fallbackName
        hasTimes = timed
        self.points = points
        self.segments = segments
        let total = points.last?.distance ?? 0
        typicalSpeed = moving > 0 ? max(total / moving, 0.5) : Self.nominalSpeed
    }

    // MARK: Derived values

    /// Sets each point's distance along the route; returns the total.
    private static func measure(_ points: inout [Point], segments: [Range<Int>]) -> Double {
        var total = 0.0
        for segment in segments {
            points[segment.lowerBound].distance = total
            for i in segment.dropFirst() {
                total += GeoMath.distance(from: points[i - 1].coordinate, to: points[i].coordinate)
                points[i].distance = total
            }
        }
        return total
    }

    /// Adds points so no step within a segment is longer than
    /// `maximumStep`, everything interpolated linearly along the step.
    /// Steps are short, so straight lines in degrees are straight enough.
    private static func densified(_ points: [Point], segments: [Range<Int>],
                                  maximumStep: Double) -> ([Point], [Range<Int>]) {
        var result: [Point] = []
        var ranges: [Range<Int>] = []
        result.reserveCapacity(points.count)
        for segment in segments {
            let start = result.count
            result.append(points[segment.lowerBound])
            for i in segment.dropFirst() {
                let a = points[i - 1], b = points[i]
                let pieces = Int((b.distance - a.distance) / maximumStep)
                if pieces > 0 {
                    for k in 1...pieces {
                        result.append(interpolate(a, b, Double(k) / Double(pieces + 1)))
                    }
                }
                result.append(b)
            }
            ranges.append(start..<result.count)
        }
        return (result, ranges)
    }

    private static func interpolate(_ a: Point, _ b: Point, _ f: Double) -> Point {
        func lerp(_ x: Double?, _ y: Double?) -> Double? {
            guard let x, let y else { return nil }
            return x + (y - x) * f
        }
        let longitudeChange = remainder(b.coordinate.longitude - a.coordinate.longitude, 360)
        var point = a
        point.coordinate = GeoCoordinate(
            latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * f,
            longitude: GeoMath.normalizedLongitude(a.coordinate.longitude + longitudeChange * f))
        point.recordedHeight = lerp(a.recordedHeight, b.recordedHeight)
        point.elevation = lerp(a.elevation, b.elevation)
        point.heartRate = lerp(a.heartRate, b.heartRate)
        point.cadence = lerp(a.cadence, b.cadence)
        if let ta = a.time, let tb = b.time {
            point.time = ta.addingTimeInterval(tb.timeIntervalSince(ta) * f)
        }
        return point
    }

    /// Distance over `speedWindow` seconds centred on each point, within its
    /// segment; at least the neighbours either side, for sparse fixes.
    private static func measureSpeed(_ points: inout [Point], segments: [Range<Int>]) {
        guard let start = points.first?.time else { return }
        let seconds = points.map { $0.time!.timeIntervalSince(start) }
        let half = speedWindow / 2
        for segment in segments {
            var low = segment.lowerBound, high = segment.lowerBound
            for i in segment {
                while seconds[low] < seconds[i] - half { low += 1 }
                high = max(high, i)
                while high + 1 < segment.upperBound, seconds[high + 1] <= seconds[i] + half { high += 1 }
                let first = low < i ? low : max(i - 1, segment.lowerBound)
                let last = high > i ? high : min(i + 1, segment.upperBound - 1)
                let span = seconds[last] - seconds[first]
                points[i].speed = span > 0 ? (points[last].distance - points[first].distance) / span : nil
            }
        }
    }

    /// Sets each point's replay time; returns the seconds spent moving
    /// (everything but pauses and the holds between segments).
    private static func assignReplayTimes(_ points: inout [Point], segments: [Range<Int>],
                                          hasTimes: Bool) -> Double {
        var clock = 0.0, moving = 0.0
        for (s, segment) in segments.enumerated() {
            if s > 0 {
                // Hold the last point a moment, then jump to the next segment.
                clock += 1
            }
            points[segment.lowerBound].replayTime = clock
            for i in segment.dropFirst() {
                let step = points[i].distance - points[i - 1].distance
                var dt = hasTimes
                    ? points[i].time!.timeIntervalSince(points[i - 1].time!)
                    : step / nominalSpeed
                if dt > pauseThreshold, step / dt < pauseSpeed {
                    dt = 1
                } else {
                    moving += dt
                }
                clock += dt
                points[i].replayTime = clock
            }
        }
        return moving
    }

    // MARK: Heights

    /// Every `spacing` metres along each segment (more widely if that would
    /// be more than `maximumCount`), plus each segment's ends: the points to
    /// sample the surface at for draping.
    func drapeIndices(spacing: Double = 40, maximumCount: Int = 400) -> [Int] {
        let budget = max(maximumCount - 2 * segments.count, 1)
        let spacing = max(spacing, length / Double(budget))
        var indices: [Int] = []
        for segment in segments {
            var last = points[segment.lowerBound].distance
            indices.append(segment.lowerBound)
            for i in segment.dropFirst() where points[i].distance - last >= spacing {
                indices.append(i)
                last = points[i].distance
            }
            if indices.last != segment.upperBound - 1 { indices.append(segment.upperBound - 1) }
        }
        return indices
    }

    /// Each point's surface height, metres above the ellipsoid: linear by
    /// distance between the samples in its segment that have one (`indices`
    /// from `drapeIndices`, `heights` the surface found there, nil where
    /// not yet sampled or missed), held past the first and last. Nil in a
    /// segment with none.
    func surfaceHeights(indices: [Int], heights: [Double?]) -> [Double?] {
        var result = [Double?](repeating: nil, count: points.count)
        let known = zip(indices, heights).compactMap { index, height in height.map { (index, $0) } }
        var k = 0
        for segment in segments {
            while k < known.count, known[k].0 < segment.lowerBound { k += 1 }
            let first = k
            while k < known.count, known[k].0 < segment.upperBound { k += 1 }
            let samples = known[first..<k]
            guard let head = samples.first, let tail = samples.last else { continue }
            var j = samples.startIndex
            for i in segment {
                if i <= head.0 { result[i] = head.1; continue }
                if i >= tail.0 { result[i] = tail.1; continue }
                while samples[j + 1].0 < i { j += 1 }
                let a = samples[j], b = samples[j + 1]
                let span = points[b.0].distance - points[a.0].distance
                let f = span > 0 ? (points[i].distance - points[a.0].distance) / span : 0
                result[i] = a.1 + (b.1 - a.1) * f
            }
        }
        return result
    }

    /// Each point's height above the ellipsoid. On the ground it's the
    /// surface plus the clearance, or the recorded height until the surface
    /// there is known; as recorded, the other way round. Sea level is the
    /// last resort.
    func heights(mode: RouteHeightMode, surface: [Double?]) -> [Double] {
        points.indices.map { i in
            let point = points[i]
            let ground = i < surface.count ? surface[i].map { $0 + Self.groundClearance } : nil
            let first = mode == .ground ? ground : point.recordedHeight
            let second = mode == .ground ? point.recordedHeight : ground
            return first ?? second
                ?? Geoid.height(latitude: point.coordinate.latitude, longitude: point.coordinate.longitude)
        }
    }

    /// ECEF positions for `heights`.
    func positions(heights: [Double]) -> [SIMD3<Double>] {
        zip(points, heights).map { Geodesy.ecef($0.coordinate, height: $1) }
    }

    // MARK: Replay

    /// The replay as a camera track: the moving point at any replay time,
    /// interpolated as TrackPlayback does, holding at each segment's end
    /// before jumping to the next.
    func playback(heights: [Double]) -> TrackPlayback? {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        return TrackPlayback(samples: zip(points, heights).map { point, height in
            CameraTrack.Sample(time: start.addingTimeInterval(point.replayTime), segment: point.segment,
                               pose: CameraPose(latitude: point.coordinate.latitude,
                                                longitude: point.coordinate.longitude,
                                                height: height, heading: 0, pitch: 0))
        })
    }

    /// The first point at or after replay time `t`, or `points.count`.
    private func firstPoint(afterReplayTime t: Double) -> Int {
        var low = 0, high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].replayTime <= t { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Metres along the route at replay time `t`.
    func distance(atReplayTime t: Double) -> Double {
        let i = firstPoint(afterReplayTime: t)
        guard i > 0 else { return 0 }
        guard i < points.count else { return length }
        let a = points[i - 1], b = points[i]
        guard a.segment == b.segment, b.replayTime > a.replayTime else { return a.distance }
        return a.distance + (b.distance - a.distance) * (t - a.replayTime) / (b.replayTime - a.replayTime)
    }

    /// Where the route is `distance` metres along it.
    func coordinate(atDistance distance: Double) -> GeoCoordinate {
        var low = 0, high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].distance <= distance { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return points[0].coordinate }
        guard low < points.count else { return points[points.count - 1].coordinate }
        let a = points[low - 1], b = points[low]
        guard b.distance > a.distance else { return a.coordinate }
        return Self.interpolate(a, b, (distance - a.distance) / (b.distance - a.distance)).coordinate
    }

    /// The direction of travel at replay time `t`, radians clockwise from
    /// north: from `lookahead` metres back along the route to as far ahead,
    /// which irons out GPS wander and corners shorter than that. Nil when
    /// those are the same place.
    func travelHeading(atReplayTime t: Double, lookahead: Double) -> Double? {
        let s = distance(atReplayTime: t)
        let behind = coordinate(atDistance: max(s - lookahead, 0))
        let ahead = coordinate(atDistance: min(s + lookahead, length))
        guard GeoMath.distance(from: behind, to: ahead) > 0.5 else { return nil }
        return GeoMath.bearing(from: behind, to: ahead)
    }

    // MARK: Framing

    /// A place showing the whole route: centred on it, wide enough for its
    /// farthest point, facing from its start toward its middle.
    var place: Place {
        var sum = SIMD3<Double>.zero
        for point in points { sum += Geodesy.ecef(point.coordinate, height: 0) }
        let centre = simd_length(sum) > 0
            ? Geodesy.geodetic(sum / Double(points.count)).coordinate
            : points[0].coordinate
        let radius = points.map { GeoMath.distance(from: centre, to: $0.coordinate) }.max() ?? 0
        let start = points[0].coordinate
        let heading = GeoMath.distance(from: start, to: centre) > 1
            ? GeoMath.bearing(from: start, to: centre) * 180 / .pi
            : 0
        return Place(id: "route", name: name, latitude: centre.latitude, longitude: centre.longitude,
                     radius: max(1.15 * radius, 150), heading: heading)
    }
}
