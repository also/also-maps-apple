import Foundation
import simd

/// A camera track as geometry for drawing: each segment's points relative to
/// a fixed ECEF origin, with each point's Douglas–Peucker drop tolerance, so
/// simplifying to any tolerance is a filter.
///
/// Points are kept in double; `points(inSegment:tolerance:)` hands them out
/// as Float relative to `origin`, which keeps about a centimetre over a few
/// hundred kilometres (Float's spacing is 8 mm from 65 km to 131 km, 3 cm
/// at 300 km).
///
/// Segments are never joined: each is simplified and drawn on its own, so a
/// camera jump leaves a gap. Within a segment, every `chunkSize`th point is
/// always kept, so a growing track only re-simplifies its last chunk.
struct TrackPath {
    /// ECEF metres; every point is relative to it.
    let origin: SIMD3<Double>

    struct Segment {
        /// The track's segment number (CameraTrack.Sample.segment).
        var number: Int
        /// Metres from `origin`, ECEF axes.
        var points: [SIMD3<Double>] = []
        /// For each point, the largest tolerance (metres) at which it's still
        /// kept: drawn at tolerance t, the points with a drop tolerance above
        /// t remain. Infinite for the ends and chunk boundaries.
        var dropTolerances: [Double] = []
    }

    private(set) var segments: [Segment] = []
    /// Bumped by every change, for redrawing.
    private(set) var version = 0

    static let chunkSize = 512

    init(origin: SIMD3<Double>) {
        self.origin = origin
    }

    /// The samples' track, its origin at the first sample; nil if empty.
    init?<S: Sequence>(samples: S) where S.Element == CameraTrack.Sample {
        var iterator = samples.makeIterator()
        guard let first = iterator.next() else { return nil }
        self.init(origin: Self.ecef(first))
        append(first)
        while let sample = iterator.next() { append(sample) }
    }

    /// The track in a file written by TrackRecorder; nil if it has no samples.
    init?(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self.init(samples: text.split(whereSeparator: \.isNewline).lazy.compactMap(CameraTrack.sample(fromLine:)))
    }

    static func ecef(_ sample: CameraTrack.Sample) -> SIMD3<Double> {
        Geodesy.ecef(latitude: sample.pose.latitude, longitude: sample.pose.longitude, height: sample.pose.height)
    }

    var pointCount: Int { segments.reduce(0) { $0 + $1.points.count } }

    mutating func append(_ sample: CameraTrack.Sample) {
        if segments.last?.number != sample.segment {
            segments.append(Segment(number: sample.segment))
        }
        let s = segments.count - 1
        segments[s].points.append(Self.ecef(sample) - origin)
        // Re-simplify the open chunk: from the last boundary before the new
        // point to the end. Chunks share their boundary point.
        let start = max(segments[s].points.count - 2, 0) / Self.chunkSize * Self.chunkSize
        let chunk = Self.dropTolerances(segments[s].points[start...])
        segments[s].dropTolerances.removeSubrange(start...)
        segments[s].dropTolerances += chunk
        version += 1
    }

    /// A segment's points kept at `tolerance`, as Float relative to `origin`.
    func points(inSegment index: Int, tolerance: Double) -> [SIMD3<Float>] {
        let segment = segments[index]
        return zip(segment.points, segment.dropTolerances)
            .filter { $0.1 > tolerance }
            .map { SIMD3<Float>($0.0) }
    }

    /// Douglas–Peucker drop tolerances for a polyline: its ends are always
    /// kept (infinity); every other point gets its distance from the chord
    /// it splits, capped by that chord's own split point, so a point is never
    /// kept without the points that made its chord. Filtering by tolerance
    /// then gives exactly what Douglas–Peucker at that tolerance would.
    static func dropTolerances(_ points: ArraySlice<SIMD3<Double>>) -> [Double] {
        let base = points.startIndex
        var tolerances = [Double](repeating: 0, count: points.count)
        guard !points.isEmpty else { return tolerances }
        tolerances[0] = .infinity
        tolerances[points.count - 1] = .infinity
        // Chords to split, with the tolerance of the point that made them.
        var stack: [(Int, Int, Double)] = [(0, points.count - 1, .infinity)]
        while let (first, last, cap) = stack.popLast() {
            guard last - first > 1 else { continue }
            let a = points[base + first], b = points[base + last]
            var farthest = first + 1
            var farthestDistance = -1.0
            for i in (first + 1)..<last {
                let d = distance(points[base + i], segmentFrom: a, to: b)
                if d > farthestDistance {
                    farthest = i
                    farthestDistance = d
                }
            }
            let tolerance = min(farthestDistance, cap)
            tolerances[farthest] = tolerance
            stack.append((first, farthest, tolerance))
            stack.append((farthest, last, tolerance))
        }
        return tolerances
    }

    /// From `p` to the nearest point of the segment from `a` to `b`.
    static func distance(_ p: SIMD3<Double>, segmentFrom a: SIMD3<Double>, to b: SIMD3<Double>) -> Double {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return simd_distance(p, a) }
        let t = simd_clamp(simd_dot(p - a, ab) / lengthSquared, 0, 1)
        return simd_distance(p, a + t * ab)
    }
}
