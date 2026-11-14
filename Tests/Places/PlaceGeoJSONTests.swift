import Foundation
import Testing

private func places(_ json: String, idPrefix: String = "") throws -> [Place] {
    try PlaceGeoJSON.places(from: Data(json.utf8), idPrefix: idPrefix)
}

struct PlaceGeoJSONTests {
    @Test func readsEveryField() throws {
        let p = try #require(try places("""
            {"type": "FeatureCollection", "features": [{
              "type": "Feature", "id": "eiffel",
              "geometry": {"type": "Point", "coordinates": [2.2945, 48.8584, 35]},
              "properties": {"name": "Eiffel Tower", "alsoMaps": {"radius": 400, "heading": 120}}
            }]}
            """).first)
        #expect(p == Place(id: "eiffel", name: "Eiffel Tower", latitude: 48.8584, longitude: 2.2945,
                           radius: 400, heading: 120, altitude: 35))
    }

    @Test func plainPointsGetDefaults() throws {
        let p = try #require(try places("""
            {"type": "Feature", "geometry": {"type": "Point", "coordinates": [-71.0605, 42.3555]},
             "properties": null}
            """).first)
        #expect(p.name == "42.3555, -71.0605")
        #expect(p.radius == PlaceGeoJSON.defaultRadius)
        #expect(p.heading == 0)
        #expect(p.altitude == nil)
        #expect(p.id == "#0")
    }

    /// Other geometry, bad points and unknown members are skipped.
    @Test func skipsWhatItCantUse() throws {
        let result = try places("""
            {"type": "FeatureCollection", "bbox": [0, 0, 1, 1], "features": [
              {"type": "Feature", "geometry": {"type": "LineString", "coordinates": [[0, 0], [1, 1]]}, "properties": {}},
              {"type": "Feature", "geometry": null, "properties": {}},
              {"type": "Feature", "geometry": {"type": "Point", "coordinates": [200, 0]}, "properties": {}},
              {"type": "Feature", "geometry": {"type": "Point", "coordinates": [true, 0]}, "properties": {}},
              {"type": "Feature", "geometry": {"type": "Point", "coordinates": [1]}, "properties": {}},
              "nonsense",
              {"type": "Feature", "geometry": {"type": "Point", "coordinates": [1, 2]},
               "properties": {"name": "", "marker-color": "#f00", "alsoMaps": {"radius": -5, "heading": "north"}}}
            ]}
            """)
        #expect(result.count == 1)
        let p = try #require(result.first)
        #expect(p.name == "2.0000, 1.0000")
        #expect(p.radius == PlaceGeoJSON.defaultRadius)
        #expect(p.heading == 0)
        #expect(p.id == "#6")
    }

    @Test func headingWraps() throws {
        let p = try #require(try places("""
            {"type": "Feature", "geometry": {"type": "Point", "coordinates": [0, 0]},
             "properties": {"alsoMaps": {"heading": -90}}}
            """).first)
        #expect(p.heading == 270)
    }

    @Test func idsArePrefixedAndUnique() throws {
        let result = try places("""
            {"type": "FeatureCollection", "features": [
              {"type": "Feature", "id": 7, "geometry": {"type": "Point", "coordinates": [0, 0]}, "properties": {}},
              {"type": "Feature", "id": 7, "geometry": {"type": "Point", "coordinates": [1, 1]}, "properties": {}}
            ]}
            """, idPrefix: "imported:")
        #expect(result.map(\.id) == ["imported:7", "imported:#1"])
    }

    @Test(arguments: ["", "[1, 2]", "{\"type\": \"Point\", \"coordinates\": [0, 0]}", "not json"])
    func rejectsWhatIsntAFeatureCollection(_ json: String) {
        #expect(throws: PlaceGeoJSON.ReadError.self) { try places(json) }
    }

    @Test func emptyCollectionHasNoPlaces() throws {
        #expect(try places(#"{"type": "FeatureCollection", "features": []}"#).isEmpty)
    }

    /// Saved views carry float noise; files get readable numbers.
    @Test func writesRoundedNumbers() throws {
        let noisy = Place(id: "a", name: "Ferry Building", latitude: 37.795690562623399, longitude: -122.3937,
                          radius: 608.95365511624937, heading: 359.99999999999562, altitude: -37.022024914622307)
        let text = try #require(String(data: PlaceGeoJSON.data(for: [noisy]), encoding: .utf8))
        #expect(text.contains("37.7956906"))
        #expect(text.contains("609"))
        #expect(!text.contains("359.99"))
        #expect(text.contains("-37.02\n") || text.contains("-37.02 "))
        #expect(!text.contains("00000"))
        let read = try #require(try PlaceGeoJSON.places(from: Data(text.utf8)).first)
        #expect(read.latitude == 37.7956906)
        #expect(read.radius == 609)
        #expect(read.heading == 0)
        #expect(read.altitude == -37.02)
    }

    @Test func roundTrips() throws {
        let saved = [
            Place(id: "a", name: "Eiffel Tower", latitude: 48.8584, longitude: 2.2945, radius: 400,
                  heading: 120, altitude: 35.5),
            Place(id: "b", name: "Somewhere / else", latitude: -33.8568, longitude: 151.2153, radius: 900),
        ]
        #expect(try PlaceGeoJSON.places(from: PlaceGeoJSON.data(for: saved)) == saved)
    }
}

@MainActor
struct PlaceStoreTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "PlaceStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func file(_ name: String, _ json: String) throws -> URL {
        let source = directory.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let url = source.appending(path: name)
        try Data(json.utf8).write(to: url)
        return url
    }

    private let point = """
        {"type": "FeatureCollection", "features": [
          {"type": "Feature", "geometry": {"type": "Point", "coordinates": [1, 2]}, "properties": {"name": "One"}}
        ]}
        """

    @Test func myMapLastsAcrossLaunches() {
        let store = PlaceStore(directory: directory)
        store.add(Place(id: "x", name: "Here", latitude: 1, longitude: 2, radius: 300, heading: 45))
        store.add(Place(id: "y", name: "There", latitude: 3, longitude: 4, radius: 300))
        store.rename("x", to: "  Home  ")
        store.remove("y")

        let relaunched = PlaceStore(directory: directory)
        #expect(relaunched.myMap == [Place(id: "x", name: "Home", latitude: 1, longitude: 2, radius: 300, heading: 45)])
    }

    @Test func importedFileLastsAcrossLaunchesUnderItsName() throws {
        let store = PlaceStore(directory: directory)
        try store.importFile(file("Trip Ideas.geojson", point))

        let relaunched = PlaceStore(directory: directory)
        #expect(relaunched.imported?.name == "Trip Ideas")
        #expect(relaunched.imported?.places.map(\.name) == ["One"])
        #expect(relaunched.imported?.places.first?.id.hasPrefix(PlaceStore.importedIDPrefix) == true)
    }

    @Test func anImportedMyMapIsMarked() throws {
        let store = PlaceStore(directory: directory)
        try store.importFile(file("My Map.alsomaps", point))
        #expect(store.imported?.name == "My Map (Imported)")
        #expect(PlaceStore(directory: directory).imported?.name == "My Map (Imported)")
    }

    @Test func importingAnotherReplacesIt() throws {
        let store = PlaceStore(directory: directory)
        try store.importFile(file("First.geojson", point))
        try store.importFile(file("Second.alsomaps", point))
        #expect(PlaceStore(directory: directory).imported?.name == "Second")
    }

    @Test func aFailedImportKeepsTheCurrentSet() throws {
        let store = PlaceStore(directory: directory)
        try store.importFile(file("Good.geojson", point))
        #expect(throws: PlaceStore.ImportError.noPlaces) {
            try store.importFile(file("Lines.geojson", """
                {"type": "FeatureCollection", "features": [
                  {"type": "Feature", "geometry": {"type": "LineString", "coordinates": [[0, 0], [1, 1]]}, "properties": {}}
                ]}
                """))
        }
        #expect(throws: PlaceStore.ImportError.notGeoJSON) { try store.importFile(file("Bad.geojson", "nope")) }
        #expect(throws: PlaceStore.ImportError.unreadable) {
            try store.importFile(directory.appending(path: "missing.geojson"))
        }
        #expect(store.imported?.name == "Good")
        #expect(PlaceStore(directory: directory).imported?.name == "Good")
    }

    @Test func removingTheImportedSetLasts() throws {
        let store = PlaceStore(directory: directory)
        try store.importFile(file("Gone.geojson", point))
        store.removeImported()
        #expect(store.imported == nil)
        #expect(PlaceStore(directory: directory).imported == nil)
    }
}

@MainActor
struct PlaceStoreMoveTests {
    @Test(arguments: [
        (IndexSet([0]), 3, ["b", "c", "a"]),
        (IndexSet([2]), 0, ["c", "a", "b"]),
        (IndexSet([0, 2]), 2, ["b", "a", "c"]),
    ])
    func movesLikeAList(source: IndexSet, destination: Int, expected: [String]) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PlaceStoreMoveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = PlaceStore(directory: directory)
        for id in ["a", "b", "c"] {
            store.add(Place(id: id, name: id, latitude: 0, longitude: 0, radius: 100))
        }
        store.move(fromOffsets: source, toOffset: destination)
        #expect(store.myMap.map(\.id) == expected)
        #expect(PlaceStore(directory: directory).myMap.map(\.id) == expected)
    }
}
