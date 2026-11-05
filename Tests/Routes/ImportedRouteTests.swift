import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_793_000_000)
/// Degrees of latitude per metre on GeoMath's sphere.
private let perMetre = 180 / (.pi * GeoMath.earthRadius)

/// A point `north` metres north of 37° N, 122° W, `time` seconds in.
private func point(_ north: Double, _ time: Double? = nil, height: Double? = nil,
                   heartRate: Double? = nil) -> RouteDocument.Point {
    RouteDocument.Point(latitude: 37 + north * perMetre, longitude: -122, height: height,
                        time: time.map { start.addingTimeInterval($0) }, heartRate: heartRate)
}

private func route(_ lines: [[RouteDocument.Point]], datum: RouteDocument.HeightDatum = .meanSeaLevel) -> ImportedRoute? {
    ImportedRoute(document: RouteDocument(name: nil, lines: lines.map { .init(track: 0, points: $0) },
                                          heightDatum: datum))
}

struct ImportedRouteTests {
    @Test func noPointsIsNoRoute() {
        #expect(route([]) == nil)
        #expect(route([[]]) == nil)
    }

    @Test func distanceRunsAlongSegmentsButNotAcrossTheGapBetweenThem() throws {
        let r = try #require(route([[point(0, 0), point(10, 5), point(20, 10)], [point(500, 20), point(510, 25)]]))
        #expect(r.segments == [0..<3, 3..<5])
        #expect(r.points.map(\.segment) == [0, 0, 0, 1, 1])
        #expect(abs(r.points[2].distance - 20) < 1e-6)
        #expect(abs(r.points[3].distance - 20) < 1e-6)
        #expect(abs(r.length - 30) < 1e-6)
    }

    @Test func speedIsSmoothedDistanceOverTime() throws {
        // 10 m every 5 s, 2 m/s, with one fix 3 m off along the line.
        let r = try #require(route([[point(0, 0), point(10, 5), point(23, 10), point(30, 15), point(40, 20)]]))
        #expect(r.hasTimes)
        let speeds = r.points.map { $0.speed ?? .nan }
        // The window spans the neighbours either side, so the jumpy fix
        // doesn't show: (30 − 10) / 10 at the third point.
        #expect(abs(speeds[2] - 2) < 1e-6)
        #expect(abs(speeds[0] - 2) < 1e-6)
        #expect(abs(speeds[4] - 2) < 1e-6)
    }

    @Test func longStepsAreFilledInWithInterpolatedPoints() throws {
        let r = try #require(route([[point(0, 0, height: 0, heartRate: 100), point(100, 50, height: 40, heartRate: 140)]]))
        // 100 m in steps of at most 30 m: three added points.
        #expect(r.points.count == 5)
        let middle = r.points[2]
        #expect(abs(middle.distance - 50) < 1e-6)
        #expect(abs((middle.elevation ?? .nan) - 20) < 1e-9)
        #expect(abs((middle.heartRate ?? .nan) - 120) < 1e-9)
        #expect(middle.time == start.addingTimeInterval(25))
    }

    @Test func pausesAreCutShortInTheReplay() throws {
        // Stopped for ten minutes (drifting a metre) between 5 s and 605 s.
        let r = try #require(route([[point(0, 0), point(10, 5), point(11, 605), point(21, 610)]]))
        #expect(r.points.map(\.replayTime) == [0, 5, 6, 11])
        // Moving 21 m in 10 s.
        #expect(abs(r.typicalSpeed - 2.1) < 1e-6)
        // Speed still uses the real times.
        #expect((r.points[2].speed ?? 1) < 0.1)
    }

    @Test func segmentsHoldASecondBeforeTheJump() throws {
        let r = try #require(route([[point(0, 0), point(10, 5)], [point(20, 3600), point(25, 3605)]]))
        #expect(r.points.map(\.replayTime) == [0, 5, 6, 11])
    }

    @Test func withoutTimesTheReplayUsesNominalSpeed() throws {
        let r = try #require(route([[point(0), point(20), point(40)]]))
        #expect(!r.hasTimes)
        #expect(r.points.allSatisfy { $0.speed == nil && $0.time == nil })
        #expect(abs(r.replayDuration - 40 / ImportedRoute.nominalSpeed) < 1e-6)
    }

    @Test func timesOutOfOrderAreIgnored() throws {
        let r = try #require(route([[point(0, 10), point(10, 5), point(20, 20)]]))
        #expect(!r.hasTimes)
    }

    @Test func seaLevelHeightsAreMovedOntoTheEllipsoid() throws {
        let geoid = Geoid.height(latitude: 37, longitude: -122)
        let msl = try #require(route([[point(0, height: 100)]]))
        #expect(abs((msl.points[0].recordedHeight ?? .nan) - (100 + geoid)) < 1e-9)
        #expect(msl.points[0].elevation == 100)
        let ellipsoid = try #require(route([[point(0, height: 100)]], datum: .ellipsoid))
        #expect(ellipsoid.points[0].recordedHeight == 100)
        #expect(abs((ellipsoid.points[0].elevation ?? .nan) - (100 - geoid)) < 1e-9)
    }

    // MARK: Draping

    @Test func drapeSamplesAreSpacedAndIncludeEveryEnd() throws {
        let r = try #require(route([[point(0), point(25), point(50), point(75), point(100)], [point(200), point(210)]]))
        let indices = r.drapeIndices(spacing: 40)
        #expect(indices == [0, 2, 4, 5, 6])
        // A tight budget spreads them out: 110 m over two, 55 m apart.
        #expect(r.drapeIndices(spacing: 1, maximumCount: 6) == [0, 3, 4, 5, 6])
    }

    @Test func surfaceIsInterpolatedByDistanceAndHeldPastTheEnds() throws {
        let r = try #require(route([[point(0), point(10), point(20), point(30), point(40)], [point(100), point(110)]]))
        let surface = r.surfaceHeights(indices: [1, 3, 5, 6], heights: [10, 30, nil, nil])
        #expect(surface[0] == 10)  // Held before the first sample.
        #expect(surface[1] == 10)
        #expect(abs((surface[2] ?? .nan) - 20) < 1e-9)
        #expect(surface[4] == 30)  // Held after the last.
        #expect(surface[5] == nil && surface[6] == nil)  // Nothing known there.
    }

    @Test func groundPrefersTheSurfaceAndRecordedPrefersTheFile() throws {
        let r = try #require(route([[point(0, height: 100), point(10)]]))
        let geoid = Geoid.height(latitude: 37, longitude: -122)
        let surface: [Double?] = [50, nil]
        let ground = r.heights(mode: .ground, surface: surface)
        #expect(abs(ground[0] - (50 + ImportedRoute.groundClearance)) < 1e-9)
        // No surface or height known: sea level.
        #expect(abs(ground[1] - Geoid.height(latitude: r.points[1].coordinate.latitude, longitude: -122)) < 1e-9)
        let recorded = r.heights(mode: .recorded, surface: surface)
        #expect(abs(recorded[0] - (100 + geoid)) < 1e-9)
    }

    // MARK: Replay

    @Test func distanceAndHeadingFollowTheReplayClock() throws {
        let r = try #require(route([[point(0, 0), point(20, 10), point(40, 20)]]))
        #expect(abs(r.distance(atReplayTime: 5) - 10) < 1e-6)
        #expect(abs(r.distance(atReplayTime: 100) - 40) < 1e-6)
        let heading = try #require(r.travelHeading(atReplayTime: 10, lookahead: 5))
        #expect(abs(heading) < 1e-6)  // North.
        let c = r.coordinate(atDistance: 30)
        #expect(abs(c.latitude - (37 + 30 * perMetre)) < 1e-9)
    }

    @Test func playbackPutsTheMovingPointOnTheRoute() throws {
        let r = try #require(route([[point(0, 0), point(20, 10)]]))
        let heights = r.heights(mode: .recorded, surface: [])
        let playback = try #require(r.playback(heights: heights))
        let pose = playback.pose(at: 5)
        #expect(abs(pose.latitude - (37 + 10 * perMetre)) < 1e-9)
        #expect(abs(playback.duration - 10) < 1e-6)
    }

    @Test func placeCoversTheRouteAndFacesFromItsStart() throws {
        let r = try #require(route([[point(0), point(1000), point(2000)]]))
        let place = r.place
        #expect(abs(place.latitude - (37 + 1000 * perMetre)) < 1e-4)
        #expect(place.radius >= 1000 && place.radius < 1300)
        #expect(abs(place.heading) < 0.01)
    }
}
