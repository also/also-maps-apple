import Foundation
import Testing

struct GPXParserTests {
    @Test func readsTracksSegmentsAndPoints() throws {
        let document = try RouteFixtures.document("garmin-run.gpx")
        #expect(document.name == "Morning Run")
        #expect(document.heightDatum == .meanSeaLevel)
        // Two segments of one track; the waypoint isn't part of either.
        #expect(document.lines.map(\.track) == [0, 0])
        #expect(document.lines.map(\.points.count) == [3, 2])
        let first = document.lines[0].points[0]
        #expect(first.latitude == 37.7955 && first.longitude == -122.3937)
        #expect(first.height == 4.2)
    }

    @Test func readsTimesInEveryCommonForm() throws {
        let points = try RouteFixtures.document("garmin-run.gpx").lines[0].points
        #expect(points[0].time == routeTime("2026-10-30T07:00:00Z"))
        #expect(points[1].time == routeTime("2026-10-30T07:00:05.500Z"))
        // An offset from UTC.
        #expect(points[2].time == routeTime("2026-10-30T07:00:10Z"))
    }

    @Test func readsGarminHeartRateAndCadence() throws {
        let points = try RouteFixtures.document("garmin-run.gpx").lines[0].points
        #expect(points.map(\.heartRate) == [120, 131, nil])
        #expect(points.map(\.cadence) == [80, 84, nil])
    }

    @Test func skipsPointsWithNoUsablePositionAndKeepsMissingValuesMissing() throws {
        let points = try RouteFixtures.document("garmin-run.gpx").lines[1].points
        #expect(points.map(\.latitude) == [37.796, 37.7961])
        #expect(points[1].height == nil)
        #expect(points[1].time == routeTime("2026-10-30T07:01:04Z"))
    }

    @Test func readsOtherPrefixesBareExtensionsAndRoutes() throws {
        let document = try RouteFixtures.document("gpx10-mixed.gpx")
        #expect(document.name == "Two kinds of line")
        #expect(document.lines.map(\.track) == [0, 1])
        #expect(document.lines[0].points.map(\.heartRate) == [150, 152])
        #expect(document.lines[0].points.map(\.cadence) == [nil, 60])
        #expect(document.lines[1].points.map(\.latitude) == [46.6, 46.61])
    }

    @Test func rejectsWhatIsntGPX() {
        let html = Data("<html><body>no</body></html>".utf8)
        #expect(RouteImport.document(from: html, fileExtension: "gpx") == .failure(.unsupported))
        let broken = Data("<gpx><trk><trkseg>".utf8)
        guard case .failure(.unreadable) = RouteImport.document(from: broken, fileExtension: "gpx") else {
            Issue.record("expected a parse failure")
            return
        }
    }

    @Test func aFileWithNoPointsIsEmpty() {
        let data = Data("<gpx version=\"1.1\"><trk><trkseg></trkseg></trk></gpx>".utf8)
        #expect(RouteImport.document(from: data, fileExtension: "gpx") == .failure(.empty))
    }
}

struct GeoJSONRouteTests {
    @Test func readsLineStringsWithTogeojsonTimesAndHeartRates() throws {
        let document = try RouteFixtures.document("ride.geojson")
        #expect(document.name == "Ride")
        #expect(document.heightDatum == .ellipsoid)
        let ride = document.lines[0].points
        #expect(ride.map(\.longitude) == [-122.39, -122.389, -122.388])
        #expect(ride.map(\.height) == [-20.5, nil, -19])
        #expect(ride.map(\.heartRate) == [100, 110, 120])
        #expect(ride[2].time == routeTime("2026-10-30T08:00:20.250Z"))
    }

    @Test func multiLineStringIsOneTrackOfSeveralLines() throws {
        let document = try RouteFixtures.document("ride.geojson")
        // The Point feature is ignored.
        #expect(document.lines.map(\.track) == [0, 1, 1])
        #expect(document.lines[2].points[1].time == routeTime("2026-10-30T09:10:05Z"))
    }

    @Test func sniffsJSONWithoutAnExtension() throws {
        let data = Data(#"  {"type":"LineString","coordinates":[[1,2],[3,4]]}"#.utf8)
        let document = try RouteImport.document(from: data).get()
        #expect(document.lines.count == 1)
        #expect(document.lines[0].points[1].latitude == 4)
    }

    @Test func rejectsJSONThatIsntGeoJSON() {
        #expect(RouteImport.document(from: Data(#"{"a":1}"#.utf8), fileExtension: "json") == .failure(.unsupported))
        let polygon = Data(#"{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]]]}"#.utf8)
        #expect(RouteImport.document(from: polygon, fileExtension: "geojson") == .failure(.empty))
    }
}
