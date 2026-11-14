import Foundation
import Testing

private final class TestBundle {}

/// Geography.sqlite, built into the test bundle by Scripts/build_geography.sh.
private let gazetteer = Gazetteer(url: Bundle(for: TestBundle.self).url(forResource: "Geography", withExtension: "sqlite"))

private let feet30k = 30_000 * 0.3048

private func camera(_ latitude: Double, _ longitude: Double, height: Double = feet30k, heading: Double = 0) -> PlaceContext.Camera {
    PlaceContext.Camera(latitude: latitude, longitude: longitude, height: height, heading: heading)
}

private let boston = GeoCoordinate(latitude: 42.3555, longitude: -71.0605)
private let worcester = GeoCoordinate(latitude: 42.2626, longitude: -71.8023)

struct GazetteerTests {
    @Test func recordsItsVersions() async throws {
        let meta = try await gazetteer.metadata()
        #expect(meta["schema_version"] == String(GeographySchema.version))
        #expect(meta["ne_populated_places"] == "5.1.2")
        #expect(meta["ne_admin_1_states_provinces"] != nil)
        #expect(meta["ne_geography_marine_polys"] != nil)
    }

    @Test func overBostonFromAPlane() async throws {
        let context = try await gazetteer.context(camera: camera(boston.latitude, boston.longitude), viewCenter: nil)
        #expect(context.below.urbanArea?.name == "Boston")
        #expect(context.below.state?.name == "Massachusetts")
        #expect(PlaceSuggestions.description(of: context) == "30,000 ft over Boston")
    }

    @Test func overWorcesterLookingTowardBoston() async throws {
        let context = try await gazetteer.context(camera: camera(worcester.latitude, worcester.longitude, heading: 80), viewCenter: boston)
        let names = PlaceSuggestions.names(for: context)
        #expect(names.first == "Over Worcester, looking toward Boston")
        #expect(names.contains("30,000 ft over Worcester"))
        #expect(names.contains("Boston from the west"))
        #expect(names.contains("Massachusetts"))
    }

    @Test func smallTownsOnlyCountNearTheGround() async throws {
        let high = try await gazetteer.surroundings(of: boston, height: 400_000)
        let low = try await gazetteer.surroundings(of: boston, height: 300)
        let highNames = Set(high.nearby.map(\.place.name))
        let lowNames = Set(low.nearby.map(\.place.name))
        #expect(highNames.count <= lowNames.count + 5)
        #expect(Gazetteer.significanceZoom(height: 400_000) < Gazetteer.significanceZoom(height: 300))
        #expect(low.urbanArea?.name == "Boston")
    }

    @Test func overNevada() async throws {
        let reno = try await gazetteer.surroundings(of: GeoCoordinate(latitude: 39.53, longitude: -119.82), height: feet30k)
        #expect(reno.state?.name == "Nevada")
        #expect(reno.urbanArea?.name == "Reno")

        // Central Nevada, far from any town that counts at this height.
        let desert = try await gazetteer.surroundings(of: GeoCoordinate(latitude: 38.9, longitude: -116.6), height: feet30k)
        #expect(desert.state?.name == "Nevada")
        #expect(desert.waters.isEmpty)
    }

    @Test func overTheOcean() async throws {
        let context = try await gazetteer.context(camera: camera(35, -40), viewCenter: nil)
        #expect(context.below.state == nil)
        #expect(context.below.urbanArea == nil)
        #expect(context.below.nearby.isEmpty)
        let water = try #require(context.below.waters.first)
        #expect(water.name == "Atlantic Ocean")
        #expect(water.localName == "North Atlantic Ocean")
        #expect(PlaceSuggestions.description(of: context) == "30,000 ft over the Atlantic Ocean")
    }

    @Test func overTheGulfOfMaine() async throws {
        let s = try await gazetteer.surroundings(of: GeoCoordinate(latitude: 43.0, longitude: -68.5), height: feet30k)
        #expect(s.state == nil)
        #expect(s.waters.first?.name == "Gulf of Maine")
        #expect(PlaceSuggestions.waterName(try #require(s.waters.first)) == "the Gulf of Maine")
    }

    @Test(arguments: [179.5, -179.5])
    func acrossTheAntimeridian(longitude: Double) async throws {
        // Chukotka spans the antimeridian.
        let s = try await gazetteer.surroundings(of: GeoCoordinate(latitude: 66.5, longitude: longitude), height: feet30k)
        let state = try #require(s.state)
        #expect(state.name.contains("Chukot"))
        #expect(state.countryCode == "RU")
        #expect(PlaceSuggestions.stateName(state).hasSuffix(", Russia"))
    }

    @Test func nearestToBostonIsBoston() async throws {
        let nearest = try await gazetteer.nearest(to: boston, within: 50_000, limit: 3)
        #expect(nearest.first?.place.name == "Boston")
        #expect(nearest.map(\.distance) == nearest.map(\.distance).sorted())
    }

    @Test func labelsMostImportantFirst() async throws {
        let newEngland = GeoBounds(south: 41, west: -74, north: 45, east: -69)
        let labels = try await gazetteer.labels(in: newEngland, zoom: 6, limit: 10)
        #expect(labels.first?.displayName == "Boston")
        #expect(labels.allSatisfy { $0.minZoom <= 6 && newEngland.contains($0.coordinate) })
        let fewer = try await gazetteer.labels(in: newEngland, zoom: 4, limit: 100)
        let more = try await gazetteer.labels(in: newEngland, zoom: 8, limit: 100)
        #expect(fewer.count < more.count)
    }

    @Test func labelsAcrossTheAntimeridian() async throws {
        let pacific = GeoBounds(south: -25, west: 170, north: -10, east: -170)
        let labels = try await gazetteer.labels(in: pacific, zoom: 7, limit: 50)
        #expect(labels.contains { $0.displayName == "Suva" })
    }

    @Test func localizedNames() async throws {
        let place = try #require(try await gazetteer.nearest(to: boston, within: 50_000, limit: 1).first)
        #expect(try await gazetteer.localizedName(id: place.place.id, language: "ja") == "ボストン")
    }

    @Test func viewCenterOfATiltedCamera() throws {
        let down = CameraPose(latitude: worcester.latitude, longitude: worcester.longitude, height: feet30k, heading: 0, pitch: -.pi / 2)
        let straightDown = try #require(Gazetteer.viewCenter(of: down))
        #expect(GeoMath.distance(from: straightDown, to: worcester) < 50)

        let east = CameraPose(latitude: worcester.latitude, longitude: worcester.longitude, height: feet30k, heading: .pi / 2, pitch: -.pi / 18)
        let ahead = try #require(Gazetteer.viewCenter(of: east))
        #expect(ahead.longitude > worcester.longitude)

        let level = CameraPose(latitude: worcester.latitude, longitude: worcester.longitude, height: feet30k, heading: 0, pitch: 0.1)
        #expect(Gazetteer.viewCenter(of: level) == nil)
    }
}

struct RegionGeometryTests {
    @Test func roundTrips() {
        let geometry = RegionGeometry(rings: [
            [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)],
            [SIMD2(4, 4), SIMD2(6, 4), SIMD2(6, 6)],
        ])
        #expect(RegionGeometry(encoded: geometry.encoded()) == geometry)
        #expect(RegionGeometry(encoded: Data([1, 2, 3])) == nil)
    }

    @Test func holesAreOutside() {
        let square = [SIMD2<Float>(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let hole = [SIMD2<Float>(4, 4), SIMD2(6, 4), SIMD2(6, 6), SIMD2(4, 6)]
        let island = [SIMD2<Float>(4.5, 4.5), SIMD2(5.5, 4.5), SIMD2(5.5, 5.5), SIMD2(4.5, 5.5)]
        let geometry = RegionGeometry(rings: [square, hole, island])
        #expect(geometry.contains(longitude: 2, latitude: 2))
        #expect(!geometry.contains(longitude: 4.2, latitude: 4.2))
        #expect(geometry.contains(longitude: 5, latitude: 5))
        #expect(!geometry.contains(longitude: 11, latitude: 5))
    }
}
