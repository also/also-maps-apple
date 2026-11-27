import Foundation
import Testing

private let lineJSON = #"{"type": "LineString", "coordinates": [[-71, 42], [-71.1, 42.1]]}"#

/// A track in the air and a line on the ground.
private let mixedKML = """
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2"><Document>
<Placemark><gx:Track><altitudeMode>absolute</altitudeMode>
<when>2026-11-02T00:00:00Z</when><when>2026-11-02T00:00:10Z</when>
<gx:coord>-71 42 500</gx:coord><gx:coord>-71 42.01 500</gx:coord>
</gx:Track></Placemark>
<Placemark><LineString><coordinates>-71,42 -71.1,42.1</coordinates></LineString></Placemark>
</Document></kml>
"""

@Suite struct TraceStoreTests {
    let root: URL
    let directory: URL
    let recordings: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "TraceStoreTests-\(UUID().uuidString)")
        directory = root.appending(path: "Traces")
        recordings = root.appending(path: "Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }

    private func store() -> TraceStore {
        TraceStore(directory: directory, recordingsDirectory: recordings)
    }

    private func add(_ text: String, _ fileExtension: String, name: String, to store: inout TraceStore) throws -> TraceEntry {
        let entry = try TraceStore.prepare(Data(text.utf8), fileExtension: fileExtension, name: name, in: directory)
        store.insert(entry)
        return entry
    }

    private func record(_ fileName: String) throws {
        let line = CameraTrack.line(Track.Sample(time: Date(timeIntervalSince1970: 0), segment: 0,
                                                 pose: CameraPose(latitude: 42, longitude: -71, height: 100,
                                                                  heading: 0, pitch: 0)))
        try Data((CameraTrack.header + "\n" + line + "\n").utf8).write(to: recordings.appending(path: fileName))
    }

    @Test func loadsGeoJSONAsLinesAndKMLAsBoth() throws {
        var store = store()
        let geoJSON = try add(lineJSON, "geojson", name: "Ride", to: &store)
        #expect(geoJSON.hasLines && !geoJSON.hasTrack && geoJSON.isShown)
        let kml = try add(mixedKML, "KML", name: "Flight", to: &store)
        #expect(kml.hasLines && kml.hasTrack)
        #expect(kml.source == .file(fileExtension: "kml"))
        // A track's place is its start.
        #expect(kml.place?.latitude == 42)
        #expect(store.entries.map(\.name) == ["Flight", "Ride"])
        #expect(try store.track(of: kml)?.samples.count == 2)
        #expect(try store.track(of: geoJSON) == nil)
    }

    @Test func keepsTheListAcrossLaunches() throws {
        var store = store()
        let entry = try add(lineJSON, "geojson", name: "Ride", to: &store)
        store.setShown(id: entry.id, false)
        let reopened = self.store()
        #expect(reopened.entries == store.entries)
        #expect(reopened.entries.first?.isShown == false)
    }

    @Test func removingAFileDeletesItsCopies() throws {
        var store = store()
        let entry = try add(lineJSON, "geojson", name: "Ride", to: &store)
        store.remove(id: entry.id)
        #expect(store.entries.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["index.json"])
    }

    @Test func joinsOnlyShownLines() throws {
        var store = store()
        #expect(store.linesCollection() == nil)
        let ride = try add(lineJSON, "geojson", name: "Ride", to: &store)
        _ = try add(mixedKML, "kml", name: "Flight", to: &store)
        func featureCount() throws -> Int {
            let data = try #require(store.linesCollection())
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (root["features"] as? [Any])?.count ?? 0
        }
        #expect(try featureCount() == 2)
        store.setShown(id: ride.id, false)
        #expect(try featureCount() == 1)
    }

    @Test func recordingsComeAndGoWithTheirFolder() throws {
        var store = store()
        try record("Track 2026-11-01 10.00.00.csv")
        try record("Track 2026-11-02 10.00.00.csv")
        try Data().write(to: recordings.appending(path: "notes.txt"))
        var changed = store.syncRecordings()
        #expect(changed)
        #expect(store.entries.map(\.name) == ["Track 2026-11-02 10.00.00", "Track 2026-11-01 10.00.00"])
        #expect(store.entries.allSatisfy { $0.hasTrack && !$0.isShown })
        #expect(store.entries.first?.place?.latitude == 42)
        changed = store.syncRecordings()
        #expect(!changed)

        // Removing a recording from the list leaves its file alone.
        let first = try #require(store.entries.first)
        store.remove(id: first.id)
        #expect(store.entries.count == 2)

        try FileManager.default.removeItem(at: recordings.appending(path: "Track 2026-11-01 10.00.00.csv"))
        changed = store.syncRecordings()
        #expect(changed)
        #expect(store.entries.map(\.name) == ["Track 2026-11-02 10.00.00"])
        #expect(try store.track(of: store.entries[0])?.samples.count == 1)
    }

    @Test func refusesFilesWithNothingToDraw() {
        func prepare(_ text: String, _ fileExtension: String) throws -> TraceEntry {
            try TraceStore.prepare(Data(text.utf8), fileExtension: fileExtension, name: "Bad", in: directory)
        }
        #expect(throws: (any Error).self) { try prepare("not json", "geojson") }
        #expect(throws: (any Error).self) { try prepare("<kml></kml>", "kml") }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
