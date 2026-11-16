import Foundation
import Testing
import simd

private let start = Date(timeIntervalSince1970: 1_793_000_000)

private func sample(_ i: Int, segment: Int = 0, latitude: Double, longitude: Double, height: Double = 1000) -> CameraTrack.Sample {
    CameraTrack.Sample(time: start.addingTimeInterval(Double(i) / 30), segment: segment,
                       pose: CameraPose(latitude: latitude, longitude: longitude, height: height, heading: 0, pitch: 0))
}

struct TrackSimplificationTests {
    private func points(_ xy: [(Double, Double)]) -> ArraySlice<SIMD3<Double>> {
        ArraySlice(xy.map { SIMD3($0.0, $0.1, 0) })
    }

    /// What plain recursive Douglas–Peucker keeps at `tolerance`.
    private func douglasPeucker(_ p: [SIMD3<Double>], _ tolerance: Double) -> Set<Int> {
        var kept: Set<Int> = [0, p.count - 1]
        func split(_ a: Int, _ b: Int) {
            guard b - a > 1 else { return }
            let (i, d) = ((a + 1)..<b).map { ($0, TrackPath.distance(p[$0], segmentFrom: p[a], to: p[b])) }
                .max { $0.1 < $1.1 }!
            guard d > tolerance else { return }
            kept.insert(i)
            split(a, i)
            split(i, b)
        }
        split(0, p.count - 1)
        return kept
    }

    @Test func endsAreAlwaysKeptAndStraightPointsDropFirst() {
        let t = TrackPath.dropTolerances(points([(0, 0), (1, 0), (2, 0), (3, 5), (4, 0)]))
        #expect(t[0] == .infinity && t[4] == .infinity)
        #expect(t[1] == 0)  // On the chord it splits.
        #expect(abs(t[3] - 5) < 1e-9)
    }

    @Test func filteringMatchesDouglasPeuckerAtEveryTolerance() {
        // A noisy wiggle: tolerances capped by their parents nest properly.
        var state: UInt64 = 42
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let p = (0..<300).map { i in SIMD3(Double(i), 20 * sin(Double(i) / 15) + 3 * random(), 2 * random()) }
        let tolerances = TrackPath.dropTolerances(ArraySlice(p))
        for tolerance in [0.01, 0.5, 1, 2, 5, 10, 30] {
            let filtered = Set(tolerances.indices.filter { tolerances[$0] > tolerance })
            #expect(filtered == douglasPeucker(p, tolerance), "tolerance \(tolerance)")
        }
    }

    @Test func repeatedPointsAreDroppedAtAnyTolerance() {
        let t = TrackPath.dropTolerances(points([(0, 0), (0, 0), (0, 0), (1, 1)]))
        #expect(t[1] == 0 && t[2] == 0)
    }

    @Test func segmentsStaySeparate() throws {
        let samples = (0..<10).map { sample($0, latitude: 37 + Double($0) * 1e-4, longitude: -122) }
            + (10..<20).map { sample($0, segment: 1, latitude: 38 + Double($0) * 1e-4, longitude: -122) }
        let path = try #require(TrackPath(samples: samples))
        #expect(path.segments.map(\.number) == [0, 1])
        #expect(path.segments.map(\.points.count) == [10, 10])
        // Each straight segment simplifies to its own two ends, never to one
        // line across the jump.
        let first = path.points(inSegment: 0, tolerance: 1)
        let second = path.points(inSegment: 1, tolerance: 1)
        #expect(first.count == 2 && second.count == 2)
        let jumpEnd = SIMD3<Float>(TrackPath.ecef(samples[10]) - path.origin)
        #expect(simd_distance(second[0], jumpEnd) < 0.01)
        #expect(simd_distance(first[1], second[0]) > 100_000)
    }

    @Test func growingMatchesBuildingAtOnceWithinAChunk() throws {
        let samples = (0..<200).map { sample($0, latitude: 37 + 1e-5 * Double($0), longitude: -122 + 1e-4 * sin(Double($0) / 9)) }
        let whole = try #require(TrackPath(samples: samples))
        let expected = TrackPath.dropTolerances(ArraySlice(whole.segments[0].points))
        #expect(whole.segments[0].dropTolerances == expected)
    }

    @Test func chunkBoundariesAreKeptAndEveryPointHasATolerance() throws {
        let count = TrackPath.chunkSize * 2 + 10
        let samples = (0..<count).map { sample($0, latitude: 37 + 1e-6 * Double($0), longitude: -122) }
        let path = try #require(TrackPath(samples: samples))
        let tolerances = path.segments[0].dropTolerances
        #expect(tolerances.count == count)
        #expect(tolerances[TrackPath.chunkSize] == .infinity)
        #expect(tolerances[2 * TrackPath.chunkSize] == .infinity)
        // A straight line keeps only its ends and the boundaries.
        #expect(path.points(inSegment: 0, tolerance: 0.01).count == 4)
    }
}

struct TrackLocalCoordinateTests {
    @Test func floatPointsKeepACentimeterHundredsOfKilometersOut() throws {
        // San Francisco to about 300 km away, high and low.
        let samples = [sample(0, latitude: 37.7955, longitude: -122.3937, height: 1500),
                       sample(1, latitude: 37.80, longitude: -122.39, height: 20),
                       sample(2, latitude: 38.9, longitude: -120.2, height: 9000),
                       sample(3, latitude: 36.0, longitude: -121.0, height: 0)]
        let path = try #require(TrackPath(samples: samples))
        #expect(path.origin == TrackPath.ecef(samples[0]))
        let local = path.points(inSegment: 0, tolerance: -1)
        #expect(local.count == samples.count)
        for (point, s) in zip(local, samples) {
            let error = simd_distance(SIMD3<Double>(point) + path.origin, TrackPath.ecef(s))
            #expect(error < 0.02, "\(s.pose.latitude), \(s.pose.longitude): \(error) m")
        }
        // Near the origin, much better than that.
        let near = simd_distance(SIMD3<Double>(local[1]) + path.origin, TrackPath.ecef(samples[1]))
        #expect(near < 0.001)
    }

    @Test func readsATrackFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TrackPathTests-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = (0..<5).map { sample($0, segment: $0 < 3 ? 0 : 1, latitude: 37 + 1e-3 * Double($0), longitude: -122) }
        let text = ([CameraTrack.header] + samples.map(CameraTrack.line)).joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let path = try #require(try TrackPath(contentsOf: url))
        #expect(path.segments.map(\.points.count) == [3, 2])
    }
}
