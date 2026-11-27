import Foundation
import Testing

private func kml(_ body: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
    <Document>\(body)</Document>
    </kml>
    """.utf8)
}

/// A gx:Track flying north from Boston, one fix every `step` seconds.
private func flight(name: String = "Flight", mode: String? = "absolute", start: String = "2026-11-02T00:00:00Z",
                    fixes: Int = 3, step: Int = 10, altitude: Double = 1000) -> String {
    let base = ISO8601DateFormatter().date(from: start)!
    let whens = (0..<fixes).map { "<when>\(ISO8601DateFormatter().string(from: base.addingTimeInterval(Double($0 * step))))</when>" }
    let coords = (0..<fixes).map { "<gx:coord>-71.0 \(42.0 + Double($0) * 0.01) \(altitude)</gx:coord>" }
    return """
    <Placemark><name>\(name)</name>
    <LookAt><altitudeMode>clampToGround</altitudeMode></LookAt>
    <gx:Track>\(mode.map { "<altitudeMode>\($0)</altitudeMode>" } ?? "")
    \(whens.joined())\(coords.joined())
    </gx:Track></Placemark>
    """
}

struct KMLFileTests {
    @Test func readsLineStringCoordinates() throws {
        let file = try KMLFile(data: kml("""
        <Placemark><name>Walk</name><LineString><coordinates>
            -71.1,42.3 -71.2,42.4,15
        </coordinates></LineString></Placemark>
        """))
        #expect(file.lines.count == 1)
        #expect(file.lines[0].name == "Walk")
        #expect(file.lines[0].altitudeMode == "clampToGround")
        #expect(file.lines[0].coordinates == [
            .init(longitude: -71.1, latitude: 42.3, altitude: 0),
            .init(longitude: -71.2, latitude: 42.4, altitude: 15),
        ])
        #expect(file.groundLines == [[[-71.1, 42.3], [-71.2, 42.4]]])
        #expect(file.track(name: "Walk") == nil)
    }

    @Test func readsTrackTimesAndModeButNotLookAtMode() throws {
        let file = try KMLFile(data: kml(flight()))
        let line = try #require(file.lines.first)
        #expect(line.altitudeMode == "absolute")
        #expect(line.coordinates.count == 3)
        #expect(line.times?.count == 3)
        #expect(line.isAirborne)
        #expect(file.groundLines.isEmpty)
    }

    @Test func absoluteLinesWithAltitudeAreAirborne() throws {
        let file = try KMLFile(data: kml("""
        <Placemark><MultiGeometry>
        <LineString><altitudeMode>absolute</altitudeMode><coordinates>-71,42,500 -71,42.1,600</coordinates></LineString>
        <LineString><altitudeMode>absolute</altitudeMode><coordinates>-71,42,0 -71,42.1,0</coordinates></LineString>
        <LineString><altitudeMode>relativeToGround</altitudeMode><coordinates>-71,42,50 -71,42.1,50</coordinates></LineString>
        </MultiGeometry></Placemark>
        """))
        #expect(file.lines.map(\.isAirborne) == [true, false, false])
        #expect(file.groundLines.count == 2)
    }

    @Test func multiTrackModeIsInherited() throws {
        let file = try KMLFile(data: kml("""
        <Placemark><gx:MultiTrack><altitudeMode>absolute</altitudeMode>
        <gx:Track><gx:coord>-71 42 100</gx:coord><gx:coord>-71 42.1 100</gx:coord></gx:Track>
        </gx:MultiTrack></Placemark>
        """))
        #expect(file.lines.first?.isAirborne == true)
        // Without its whens the track has no times.
        #expect(file.lines.first?.times == nil)
    }

    @Test func dropsLinesWithOnePoint() throws {
        let file = try KMLFile(data: kml("""
        <Placemark><LineString><coordinates>-71,42</coordinates></LineString></Placemark>
        <Placemark><LineString><coordinates>-71,42 -71,42.1</coordinates></LineString></Placemark>
        """))
        #expect(file.lines.count == 1)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: KMLFile.Failure.self) { try KMLFile(data: Data("{}".utf8)) }
        #expect(throws: KMLFile.Failure.self) { try KMLFile(data: Data("<gpx></gpx>".utf8)) }
        #expect(throws: KMLFile.Failure.self) {
            try KMLFile(data: kml("<Placemark><Point><coordinates>-71,42</coordinates></Point></Placemark>"))
        }
    }

    @Test func trackKeepsTimesAndFacesTravel() throws {
        let file = try KMLFile(data: kml(flight(fixes: 3, step: 10, altitude: 1000)))
        let track = try #require(file.track(name: "Flight"))
        #expect(track.name == "Flight")
        #expect(track.samples.count == 3)
        let times = track.samples.map { $0.time.timeIntervalSince(track.samples[0].time) }
        #expect(times.map { ($0 * 1000).rounded() } == [0, 10_000, 20_000])
        // Flying north.
        #expect(track.samples.allSatisfy { abs($0.pose.heading) < 1e-6 })
        #expect(track.samples.allSatisfy { $0.pose.height == 1000 })
        #expect(track.start?.latitude == 42.0)
    }

    @Test func tracksAreSegmentsInTimeOrderWithGapsCut() throws {
        let file = try KMLFile(data: kml(
            flight(name: "Second", start: "2026-11-02T05:00:00Z") + flight(name: "First", start: "2026-11-02T00:00:00Z")))
        let track = try #require(file.track(name: "Both"))
        #expect(track.samples.map(\.segment) == [0, 0, 0, 1, 1, 1])
        let playback = try #require(TrackPlayback(track))
        // Two 20 s flights and a 1 s gap, not five hours.
        #expect(abs(playback.duration - 41) < 1e-6)
    }

    @Test func longTracksAreSpedUp() throws {
        let file = try KMLFile(data: kml(flight(fixes: 4, step: 3600)))
        let playback = try #require(file.track(name: "Long").flatMap(TrackPlayback.init))
        #expect(abs(playback.duration - KMLFile.longestPlayback) < 1e-6)
    }

    @Test func linesWithoutTimesFlyAtASteadySpeed() throws {
        let file = try KMLFile(data: kml("""
        <Placemark><LineString><altitudeMode>absolute</altitudeMode>
        <coordinates>-71,42,300 -71,42.009,300</coordinates></LineString></Placemark>
        """))
        let playback = try #require(file.track(name: "Line").flatMap(TrackPlayback.init))
        let meters = 0.009 * 111_320
        #expect(abs(playback.duration - meters / KMLFile.speedWithoutTimes) < 1e-6)
    }

    @Test func headingIgnoresJitterWithinTheBaseline() {
        // East, with a fix that steps 2 m back west in the middle.
        let meter = 1 / (111_320 * cos(42 * Double.pi / 180))
        let longitudes = [0, 10, 20, 18, 30, 40, 50].map { -71 + Double($0) * meter }
        let coordinates = longitudes.map { KMLFile.Coordinate(longitude: $0, latitude: 42, altitude: 0) }
        let headings = KMLFile.headings(coordinates)
        #expect(headings.allSatisfy { abs($0 - Double.pi / 2) < 0.01 })
    }
}
