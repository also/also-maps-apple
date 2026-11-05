import Foundation
import Testing
import simd

private func report(_ id: String = "a", latitude: Double = 37.6, longitude: Double = -122.3,
                    height: Double? = 1000, speed: Double? = 100, track: Double? = 0,
                    climb: Double? = 0, age: Double = 0, onGround: Bool = false) -> AircraftReport {
    AircraftReport(id: id, callsign: nil, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                   height: height, heightSource: height == nil ? .ground : .geometric, onGround: onGround,
                   groundSpeed: speed, track: track, verticalRate: climb, category: nil, positionAge: age)
}

private func geodetic(_ p: SIMD3<Double>) -> (coordinate: GeoCoordinate, height: Double) { Geodesy.geodetic(p) }

struct DeadReckoningTests {
    @Test func movesAlongTheTrackFromWhenThePositionWasMeasured() {
        // Measured 2 s before it arrived at t = 100, heading east at 100 m/s,
        // climbing 5 m/s.
        let motion = AircraftMotion(report: report(track: .pi / 2, climb: 5, age: 2), receivedAt: 100)
        let start = Geodesy.ecef(GeoCoordinate(latitude: 37.6, longitude: -122.3), height: 1000)
        let p = motion.position(at: 108, groundHeight: 0)
        // 10 s since the fix: 1 km along, 50 m up.
        let (coordinate, height) = geodetic(p)
        #expect(abs(GeoMath.distance(from: GeoCoordinate(latitude: 37.6, longitude: -122.3), to: coordinate) - 1000) < 1)
        #expect(coordinate.longitude > -122.3)
        #expect(abs(height - 1050) < 0.01)
        #expect(simd_distance(p, start) > 999)
    }

    @Test func stopsExtrapolatingAfterAWhile() {
        let motion = AircraftMotion(report: report(), receivedAt: 0)
        let limit = AircraftMotion.maximumExtrapolation
        #expect(motion.position(at: limit, groundHeight: 0) == motion.position(at: limit + 60, groundHeight: 0))
    }

    @Test func aGroundReportWithoutHeightUsesTheHostsGround() {
        let motion = AircraftMotion(report: report(height: nil, speed: 5, climb: 0, onGround: true), receivedAt: 0)
        #expect(abs(geodetic(motion.position(at: 1, groundHeight: -30)).height - -30) < 0.01)
    }

    @Test func aNewReportEasesInsteadOfJumping() {
        var motion = AircraftMotion(report: report(), receivedAt: 0)
        let before = motion.position(at: 10, groundHeight: 0)
        // The new report puts it 200 m further east than it was being shown.
        let shifted = GeoMath.offset(GeoCoordinate(latitude: 37.6, longitude: -122.3), east: 200, north: 1000)
        let updated = motion.update(with: report(latitude: shifted.latitude, longitude: shifted.longitude),
                                    receivedAt: 10, groundHeight: 0)
        #expect(updated)
        // Shown where it was at the moment the report arrives...
        #expect(simd_distance(motion.position(at: 10, groundHeight: 0), before) < 1e-6)
        // ...and on the new track a few seconds later.
        let settled = motion.position(at: 10 + 2 * AircraftMotion.easeDuration, groundHeight: 0)
        #expect(simd_distance(settled, motion.deadReckoned(at: 10 + 2 * AircraftMotion.easeDuration, groundHeight: 0)) < 1)
    }

    @Test func aHugeJumpSnapsAndRestartsTheTrail() {
        var motion = AircraftMotion(report: report(), receivedAt: 0)
        for t in stride(from: 0.0, through: 10, by: 1) { motion.sampleTrail(at: t, groundHeight: 0) }
        #expect(motion.trail.count == 6)
        motion.update(with: report(latitude: 38.6), receivedAt: 10, groundHeight: 0)
        #expect(motion.trail.isEmpty)
        #expect(motion.position(at: 10, groundHeight: 0) == motion.deadReckoned(at: 10, groundHeight: 0))
    }

    @Test func theSameReportAgainChangesNothing() {
        var motion = AircraftMotion(report: report(age: 1), receivedAt: 10)
        // Served again a second later, a second older.
        #expect(!motion.update(with: report(age: 2), receivedAt: 11, groundHeight: 0))
    }

    @Test func trailsKeepTheirLastFewMinutes() {
        var motion = AircraftMotion(report: report(), receivedAt: 0)
        for t in stride(from: 0.0, through: 400, by: 0.5) { motion.sampleTrail(at: t, groundHeight: 0) }
        let ages = motion.trail.map { 400 - $0.time }
        #expect(ages.max()! <= AircraftMotion.trailDuration)
        #expect(ages.count == Int(AircraftMotion.trailDuration / AircraftMotion.trailInterval) + 1)
    }

    @Test func pitchFollowsTheClimbWithinLimits() {
        #expect(abs(AircraftMotion(report: report(speed: 100, climb: 10), receivedAt: 0).attitude.pitch
                    - atan2(10, 100)) < 1e-12)
        #expect(AircraftMotion(report: report(speed: 10, climb: -50), receivedAt: 0).attitude.pitch
                == -AircraftMotion.maximumPitch)
        #expect(AircraftMotion(report: report(speed: 0.5, climb: 3), receivedAt: 0).attitude.pitch == 0)
    }
}

struct AirTrafficTrackerTests {
    @Test func dropsAircraftNoLongerHeardFrom() {
        var tracker = AirTrafficTracker()
        tracker.merge(AirTrafficSnapshot(reports: [report("a"), report("b")]), receivedAt: 0, groundHeight: 0)
        tracker.merge(AirTrafficSnapshot(reports: [report("b")]), receivedAt: 30, groundHeight: 0)
        #expect(tracker.advance(to: 31, groundHeight: 0).map(\.id) == ["a", "b"])
        #expect(tracker.advance(to: 50, groundHeight: 0).map(\.id) == ["b"])
        #expect(tracker.advance(to: 80, groundHeight: 0).isEmpty)
    }

    @Test func eachTrailEndsAtTheAircraft() {
        var tracker = AirTrafficTracker()
        tracker.merge(AirTrafficSnapshot(reports: [report()]), receivedAt: 0, groundHeight: 0)
        _ = tracker.advance(to: 0, groundHeight: 0)
        let state = tracker.advance(to: 3, groundHeight: 0)[0]
        #expect(state.trail.map(\.age) == [3, 0, 0])
        #expect(state.trail.last!.position == state.position)
        #expect(abs(state.height - 1000) < 0.01)
    }
}

struct TrailBandTests {
    private func points(_ ages: [Double]) -> [(age: Double, position: SIMD3<Double>)] {
        ages.map { (age: $0, position: SIMD3($0, 0, 0)) }
    }

    @Test func splitsByAgeSharingBoundaries() {
        let bands = TrailBands.split(points([170, 130, 100, 50, 20, 0]), bands: 4, duration: 180)
        // Bands of 45 s: [0, 45), [45, 90), [90, 135), [135, 180].
        #expect(bands.map { $0.map(\.x) } == [[20, 0], [50, 20], [130, 100, 50], [170, 130]])
    }

    @Test func dropsWhatsTooOld() {
        let bands = TrailBands.split(points([200, 10, 0]), bands: 2, duration: 180)
        #expect(bands.map { $0.map(\.x) } == [[10, 0], []])
    }
}

struct AircraftPoseTests {
    @Test func levelAndNorthIsTheAnchorFrame() {
        let coordinate = GeoCoordinate(latitude: 37.6, longitude: -122.3)
        let pose = simd_double3x3(AircraftPose.rotation(heading: 0, pitch: 0, at: coordinate))
        let anchor = Geodesy.anchorFrameRotation(latitude: 37.6, longitude: -122.3)
        for column in 0..<3 {
            #expect(simd_distance(pose[column], anchor[column]) < 1e-9)
        }
    }

    @Test func theNoseFollowsHeadingAndPitch() {
        let coordinate = GeoCoordinate(latitude: 0, longitude: 0)
        let frame = Geodesy.enu(latitude: 0, longitude: 0)
        let pose = AircraftPose.rotation(heading: .pi / 2, pitch: .pi / 6, at: coordinate)
        let nose = pose.act(SIMD3(0, 0, -1))
        #expect(abs(simd_dot(nose, frame.east) - cos(Double.pi / 6)) < 1e-9)
        #expect(abs(simd_dot(nose, frame.up) - sin(Double.pi / 6)) < 1e-9)
        // Wings stay level.
        #expect(abs(simd_dot(pose.act(SIMD3(1, 0, 0)), frame.up)) < 1e-9)
    }
}
