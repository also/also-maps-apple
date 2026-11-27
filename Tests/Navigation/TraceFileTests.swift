import Foundation
import Testing

@Suite struct TraceFileTests {
    private func file(_ json: String) throws -> TraceFile {
        try TraceFile(geoJSON: Data(json.utf8), name: "test")
    }

    private func featureList(_ file: TraceFile) throws -> [[String: Any]] {
        try #require(try JSONSerialization.jsonObject(with: file.features) as? [[String: Any]])
    }

    @Test func dropsShortLinesAndTheFeaturesLeftEmpty() throws {
        let cleaned = try file("""
        {"type": "FeatureCollection", "features": [
          {"type": "Feature", "properties": {}, "geometry": {"type": "MultiLineString",
            "coordinates": [[[-71, 42]], [[-71, 42], [-71.1, 42.1]]]}},
          {"type": "Feature", "properties": {}, "geometry": {"type": "MultiLineString",
            "coordinates": [[[-71, 42]]]}},
          {"type": "Feature", "properties": {}, "geometry": {"type": "LineString", "coordinates": [[-71, 42]]}},
          {"type": "Feature", "properties": {}, "geometry": null}
        ]}
        """)
        #expect(cleaned.lineCount == 1)
        let features = try featureList(cleaned)
        #expect(features.count == 1)
        let geometry = try #require(features[0]["geometry"] as? [String: Any])
        #expect((geometry["coordinates"] as? [Any])?.count == 1)
    }

    @Test func placeIsAtTheMedianLineNotAnOutlier() throws {
        func line(_ longitude: Double, _ latitude: Double) -> String {
            #"{"type": "LineString", "coordinates": [[\#(longitude), \#(latitude)], [\#(longitude), \#(latitude)]]}"#
        }
        let lines = [line(-71, 42), line(-71, 42), line(-71, 42), line(-71, 42), line(5, 52)]
        let cleaned = try file(#"{"type": "GeometryCollection", "geometries": [\#(lines.joined(separator: ","))]}"#)
        #expect(cleaned.place.latitude == 42)
        #expect(cleaned.place.longitude == -71)
        #expect(cleaned.place.radius == 500)
    }

    @Test func bareGeometryBecomesAFeature() throws {
        let features = try featureList(file(#"{"type": "LineString", "coordinates": [[-71, 42], [-71.1, 42.1]]}"#))
        #expect(features.count == 1)
        #expect(features[0]["type"] as? String == "Feature")
        #expect((features[0]["geometry"] as? [String: Any])?["type"] as? String == "LineString")
    }

    @Test func collectionJoinsFilesAndSkipsEmptyOnes() throws {
        let a = try file(#"{"type": "LineString", "coordinates": [[-71, 42], [-71.1, 42.1]]}"#)
        let b = try TraceFile(lines: [[[5, 52], [5.1, 52.1]]], name: "b")
        let joined = TraceFile.collection([a.features, Data("[ ]".utf8), b.features])
        let root = try #require(try JSONSerialization.jsonObject(with: joined) as? [String: Any])
        #expect(root["type"] as? String == "FeatureCollection")
        #expect((root["features"] as? [Any])?.count == 2)
        let empty = try #require(try JSONSerialization.jsonObject(with: TraceFile.collection([])) as? [String: Any])
        #expect((empty["features"] as? [Any])?.isEmpty == true)
    }

    @Test func refusesWhatItCantDraw() {
        #expect(throws: TraceFile.Failure.notGeoJSON) { try file("[1, 2]") }
        #expect(throws: TraceFile.Failure.notGeoJSON) { try file("not json") }
        #expect(throws: TraceFile.Failure.noLines) {
            try file(#"{"type": "Point", "coordinates": [-71, 42]}"#)
        }
    }
}
