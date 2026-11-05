import Foundation
import simd

/// What an imported route's colour shows.
enum RouteColouring: String, CaseIterable, Identifiable {
    case speed
    case elevation
    case heartRate
    case cadence
    /// One colour, like a camera track.
    case plain

    var id: Self { self }

    var name: String {
        switch self {
        case .speed: "Speed"
        case .elevation: "Elevation"
        case .heartRate: "Heart rate"
        case .cadence: "Cadence"
        case .plain: "Single colour"
        }
    }

    /// Each point's value, in the units `label` shows (speed in km/h,
    /// elevation in metres above sea level), or nil where it has none.
    func values(_ route: ImportedRoute) -> [Double?] {
        route.points.map { point in
            switch self {
            case .speed: point.speed.map { $0 * 3.6 }
            case .elevation: point.elevation
            case .heartRate: point.heartRate
            case .cadence: point.cadence
            case .plain: nil
            }
        }
    }

    /// Whether the route has anything to show this way.
    func isAvailable(for route: ImportedRoute) -> Bool {
        self == .plain || values(route).contains { $0 != nil }
    }

    /// The narrowest range a scale spans, so a flat ride isn't drawn as a
    /// rainbow of tiny differences.
    var minimumSpan: Double {
        switch self {
        case .speed: 2       // km/h
        case .elevation: 10  // m
        case .heartRate: 10  // bpm
        case .cadence: 10    // per minute
        case .plain: 1
        }
    }

    func label(_ value: Double) -> String {
        switch self {
        case .speed: String(format: "%.0f km/h", value)
        case .elevation: String(format: "%.0f m", value)
        case .heartRate: String(format: "%.0f bpm", value)
        case .cadence: String(format: "%.0f/min", value)
        case .plain: ""
        }
    }
}

/// Values binned into `binCount` colours, evenly between the 5th and 95th
/// percentiles so a few outliers (a GPS spike, a sensor dropout) don't
/// squash everything else into one colour. Values beyond either end take
/// the end's colour.
///
/// The tube is drawn as one mesh per colour (RouteOverlay), so colours are
/// a short, fixed list: the bins, then no data, then the single colour.
struct RouteColourScale: Equatable {
    static let binCount = 8
    /// Where there's no value (a heart-rate strap that dropped out).
    static let noDataBin = binCount
    /// For `.plain`.
    static let plainBin = binCount + 1
    static let colourCount = binCount + 2

    /// sRGB, 0–1, for each bin from low to high, then no data and plain:
    /// blue through green and yellow to red, bright enough to read over
    /// photographs of the ground.
    static let colours: [SIMD3<Float>] = [
        [0.23, 0.30, 0.75],  // #3B4CC0
        [0.18, 0.56, 0.85],  // #2F8FD8
        [0.17, 0.77, 0.75],  // #2CC4C0
        [0.37, 0.82, 0.41],  // #5FD068
        [0.79, 0.87, 0.23],  // #C9DD3A
        [0.98, 0.77, 0.19],  // #FBC531
        [0.97, 0.51, 0.18],  // #F7812D
        [0.88, 0.22, 0.24],  // #E0393E
        [0.60, 0.60, 0.60],  // No data.
        [1.00, 0.58, 0.00],  // Plain: systemOrange, as camera tracks.
    ]

    var lower: Double
    var upper: Double

    /// Nil if there are no values.
    init?(values: [Double?], minimumSpan: Double) {
        let sorted = values.compactMap { $0 }.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        var lower = sorted[Int(0.05 * Double(sorted.count - 1))]
        var upper = sorted[Int((0.95 * Double(sorted.count - 1)).rounded(.up))]
        if upper - lower < minimumSpan {
            let middle = (lower + upper) / 2
            lower = middle - minimumSpan / 2
            upper = middle + minimumSpan / 2
        }
        self.lower = lower
        self.upper = upper
    }

    init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    func bin(_ value: Double?) -> Int {
        guard let value, value.isFinite else { return Self.noDataBin }
        let f = (value - lower) / (upper - lower)
        return min(max(Int((f * Double(Self.binCount)).rounded(.down)), 0), Self.binCount - 1)
    }

    /// The values bin `i` covers (the first and last also cover everything
    /// beyond them).
    func range(ofBin i: Int) -> ClosedRange<Double> {
        let width = (upper - lower) / Double(Self.binCount)
        return (lower + Double(i) * width)...(lower + Double(i + 1) * width)
    }
}

/// A stretch of route drawn in one colour: consecutive steps in the same
/// bin, sharing its first and last points with the runs either side so the
/// tube has no gaps.
struct RouteRun {
    var bin: Int
    /// Metres from `RouteGeometry.origin`, ECEF axes.
    var points: [SIMD3<Double>]
    /// Douglas–Peucker drop tolerances (TrackPath.dropTolerances).
    var dropTolerances: [Double]

    /// The points kept at `tolerance`, as Float relative to the origin.
    func points(tolerance: Double) -> [SIMD3<Float>] {
        zip(points, dropTolerances).filter { $0.1 > tolerance }.map { SIMD3<Float>($0.0) }
    }
}

/// A route as coloured runs, ready for the tube: what RouteOverlay draws.
struct RouteGeometry {
    /// ECEF metres; the route's first point.
    let origin: SIMD3<Double>
    /// Up at the origin, ECEF axes: the way a draped route is lifted.
    let up: SIMD3<Double>
    let runs: [RouteRun]
    /// Draped routes are lifted by the tube's radius, so the tube sits on
    /// the surface instead of half in it.
    let liftsByRadius: Bool

    /// Each step (between consecutive points) takes the bin of the mean of
    /// its ends' values, or of the one that has one; runs never cross from
    /// one segment to the next. `scale` nil draws everything in the plain
    /// colour.
    init(route: ImportedRoute, positions: [SIMD3<Double>], values: [Double?],
         scale: RouteColourScale?, liftsByRadius: Bool) {
        let first = route.points[0].coordinate
        origin = positions[0]
        up = Geodesy.enu(latitude: first.latitude, longitude: first.longitude).up
        self.liftsByRadius = liftsByRadius

        func stepBin(_ i: Int) -> Int {
            guard let scale else { return RouteColourScale.plainBin }
            let value: Double? = switch (values[i], values[i + 1]) {
            case let (a?, b?): (a + b) / 2
            case let (a?, nil): a
            case let (nil, b?): b
            case (nil, nil): nil
            }
            return scale.bin(value)
        }

        var runs: [RouteRun] = []
        func emit(_ range: ClosedRange<Int>, bin: Int) {
            let points = range.map { positions[$0] - positions[0] }
            runs.append(RouteRun(bin: bin, points: points,
                                 dropTolerances: TrackPath.dropTolerances(points[...])))
        }
        for segment in route.segments where segment.count > 1 {
            var start = segment.lowerBound
            var bin = stepBin(start)
            for i in segment.lowerBound..<(segment.upperBound - 1) {
                let next = stepBin(i)
                if next != bin {
                    emit(start...i, bin: bin)
                    start = i
                    bin = next
                }
            }
            emit(start...(segment.upperBound - 1), bin: bin)
        }
        self.runs = runs
    }
}
