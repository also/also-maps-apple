import Foundation

/// Answers "where is this?" from the bundled Natural Earth data
/// (Geography.sqlite, built by Scripts/build_geography.sh).
///
/// Places are loaded into memory on first use; 7,342 of them scan in well
/// under a millisecond. Region polygons stay on disk: a lookup reads only
/// the regions whose ring boxes contain the point.
///
/// Every query filters by significance, which depends on altitude: from
/// high up only big cities count, near the ground small towns do too. The
/// mapping and weights are in `significanceZoom` and `nearbyRadius`, tuned
/// against GazetteerTests.
actor Gazetteer {
    static let shared = Gazetteer(url: Bundle.main.url(forResource: "Geography", withExtension: "sqlite"))

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// A populated place, as loaded into memory.
    struct Place: Equatable {
        var id: Int
        var wikidata: String?
        var name: String
        var displayName: String
        var state: String?
        var country: String?
        var countryCode: String?
        var kind: String
        var coordinate: GeoCoordinate
        var scaleRank: Int
        var labelRank: Int
        var minZoom: Double
        var population: Int?
        /// The urban area's bounding box, when Natural Earth has one.
        var urbanArea: GeoBounds?

        var feature: PlaceContext.Feature {
            PlaceContext.Feature(
                id: id, wikidata: wikidata, name: displayName, localName: name == displayName ? nil : name,
                kind: kind, state: state, country: country, countryCode: countryCode,
                population: population, rank: scaleRank)
        }
    }

    private let url: URL?
    private var database: SQLiteDatabase?
    private var loadedPlaces: [Place]?
    private var loadedPlaceNames: Set<String>?
    private var geometryCache: [Int: RegionGeometry] = [:]

    init(url: URL?) {
        self.url = url
    }

    // MARK: Significance

    /// The web-map zoom level of the least significant place worth naming
    /// from `height` meters up: about 7.8 at 30,000 ft (Worcester, MA, but
    /// not smaller towns), 4.4 at 100 km (Boston), 1.1 at 1,000 km (only
    /// the largest cities). Compared with Natural Earth's `min_zoom`.
    static func significanceZoom(height: Double) -> Double {
        min(max(21 - log2(max(height, 1)), 0), 12)
    }

    /// How far to look for nearby places from `height` meters up: 12 times
    /// the height, between 15 km and 1,500 km. About 110 km at 30,000 ft.
    static func nearbyRadius(height: Double) -> Double {
        min(max(height * 12, 15_000), 1_500_000)
    }

    // MARK: Queries

    /// The context for a camera pose: what's below it, and what's at the
    /// center of the view when that's somewhere else.
    func context(for pose: CameraPose) throws -> PlaceContext {
        try context(
            camera: PlaceContext.Camera(
                latitude: pose.latitude, longitude: pose.longitude, height: pose.height,
                heading: pose.heading * 180 / .pi),
            viewCenter: Self.viewCenter(of: pose))
    }

    /// The context for a camera at `camera` looking at `viewCenter`. The
    /// view center is left out when it's within 500 m of the point below.
    func context(camera: PlaceContext.Camera, viewCenter: GeoCoordinate?) throws -> PlaceContext {
        let below = GeoCoordinate(latitude: camera.latitude, longitude: camera.longitude)
        var center: PlaceContext.ViewCenter?
        if let viewCenter {
            let distance = GeoMath.distance(from: below, to: viewCenter)
            if distance >= 500 {
                center = PlaceContext.ViewCenter(
                    surroundings: try surroundings(of: viewCenter, height: camera.height),
                    distance: distance,
                    bearing: Self.degrees(GeoMath.bearing(from: below, to: viewCenter)))
            }
        }
        return PlaceContext(camera: camera, below: try surroundings(of: below, height: camera.height), viewCenter: center)
    }

    /// What's at `coordinate`, as seen from `height` meters up.
    func surroundings(of coordinate: GeoCoordinate, height: Double) throws -> PlaceContext.Surroundings {
        let zoom = Self.significanceZoom(height: height)
        let significant = try places().filter { $0.minZoom <= zoom }
        // Urban boxes overlap (Newark's covers Midtown Manhattan), so among
        // the boxes containing the point, the most relevant place wins, by
        // the same measure as `nearby`.
        let urban = significant
            .filter { $0.urbanArea?.contains(coordinate) == true }
            .min {
                Self.relevance($0, distance: GeoMath.distance(from: $0.coordinate, to: coordinate))
                    < Self.relevance($1, distance: GeoMath.distance(from: $1.coordinate, to: coordinate))
            }
        let nearby = Self.nearby(coordinate, in: significant, within: Self.nearbyRadius(height: height), limit: 5)
            .filter { $0.place.id != urban?.id }
        let regions = try regions(containing: coordinate)
        return PlaceContext.Surroundings(
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            urbanArea: urban?.feature, nearby: nearby, state: regions.state, waters: regions.waters)
    }

    /// Places within `radius` meters of `coordinate`, nearest first,
    /// regardless of significance. For suggesting names near a saved place.
    func nearest(to coordinate: GeoCoordinate, within radius: Double, limit: Int) throws -> [PlaceContext.Nearby] {
        try places()
            .lazy
            .map { (place: $0, distance: GeoMath.distance(from: $0.coordinate, to: coordinate)) }
            .filter { $0.distance <= radius }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map { Self.nearbyEntry($0.place, distance: $0.distance, to: coordinate) }
    }

    /// Places to label within `bounds` at map zoom `zoom`, most important
    /// first: those whose `min_zoom` is at most `zoom`, by label rank, then
    /// scale rank, then population.
    func labels(in bounds: GeoBounds, zoom: Double, limit: Int) throws -> [Place] {
        Array(try places()
            .filter { $0.minZoom <= zoom && bounds.contains($0.coordinate) }
            .sorted {
                ($0.labelRank, $0.scaleRank, -($0.population ?? 0)) < ($1.labelRank, $1.scaleRank, -($1.population ?? 0))
            }
            .prefix(limit))
    }

    /// The state or province, and the named waters, containing `coordinate`.
    func regions(containing coordinate: GeoCoordinate) throws -> (state: PlaceContext.Region?, waters: [PlaceContext.Region]) {
        let db = try open()
        let candidates = try db.prepare("""
            SELECT DISTINCT r.id, r.layer, r.kind, r.wikidata, r.name, r.display_name, r.country, r.country_code, r.scalerank
            FROM region_rings b JOIN regions r ON r.id = b.region
            WHERE b.west <= ?1 AND b.east >= ?1 AND b.south <= ?2 AND b.north >= ?2
            """).bind(coordinate.longitude, coordinate.latitude)
        var state: PlaceContext.Region?
        var waters: [(region: PlaceContext.Region, rank: Double)] = []
        while try candidates.step() {
            let id = candidates.int(0)
            guard try geometry(id: id).contains(longitude: coordinate.longitude, latitude: coordinate.latitude) else { continue }
            let name = candidates.text(4) ?? "", displayName = candidates.text(5) ?? name
            let countryCode = candidates.text(7)
            let region = PlaceContext.Region(
                id: id, wikidata: candidates.text(3), name: displayName, localName: name == displayName ? nil : name,
                kind: candidates.text(2), country: candidates.text(6), countryCode: countryCode,
                sharesNameWithPlace: try placeNames().contains(Self.nameKey(displayName, countryCode)))
            if candidates.text(1) == "admin1" {
                state = state ?? region
            } else {
                waters.append((region, candidates.optionalDouble(8) ?? 0))
            }
        }
        // Higher scale ranks are smaller features: the Gulf of Maine before
        // the North Atlantic Ocean.
        return (state, waters.sorted { $0.rank > $1.rank }.map(\.region))
    }

    /// A feature's name in `language` (a Natural Earth code: "fr", "ja",
    /// "zh-Hans", …), or nil when Natural Earth has none or it's the same as
    /// the feature's own name.
    func localizedName(id: Int, language: String) throws -> String? {
        let statement = try open().prepare("SELECT name FROM names WHERE id = ? AND language = ?").bind(id, language)
        return try statement.step() ? statement.text(0) : nil
    }

    /// The `meta` table: schema version, Natural Earth versions, tolerance.
    func metadata() throws -> [String: String] {
        let statement = try open().prepare("SELECT key, value FROM meta")
        var result: [String: String] = [:]
        while try statement.step() {
            if let key = statement.text(0) { result[key] = statement.text(1) }
        }
        return result
    }

    // MARK: Geometry

    /// Where the camera's forward ray meets the ellipsoid, or nil when it
    /// points above the horizon.
    static func viewCenter(of pose: CameraPose) -> GeoCoordinate? {
        guard case let .hit(point, _) = Geodesy.intersect(
            ray: Ray(origin: pose.position, direction: pose.basis.forward), surfaceHeight: 0)
        else { return nil }
        return Geodesy.geodetic(point).coordinate
    }

    static func nearby(_ coordinate: GeoCoordinate, in places: [Place], within radius: Double, limit: Int) -> [PlaceContext.Nearby] {
        var candidates: [(place: Place, distance: Double, score: Double)] = []
        for place in places {
            let distance = GeoMath.distance(from: place.coordinate, to: coordinate)
            if distance <= radius {
                candidates.append((place, distance, relevance(place, distance: distance)))
            }
        }
        candidates.sort { $0.score < $1.score }
        return candidates.prefix(limit).map { nearbyEntry($0.place, distance: $0.distance, to: coordinate) }
    }

    /// Lower is more relevant: distance weighted by scale rank, so Boston
    /// 60 km away (rank 2) beats a rank-8 town 25 km away.
    static func relevance(_ place: Place, distance: Double) -> Double {
        distance * Double(1 + place.scaleRank)
    }

    private static func nearbyEntry(_ place: Place, distance: Double, to coordinate: GeoCoordinate) -> PlaceContext.Nearby {
        PlaceContext.Nearby(
            place: place.feature, distance: distance,
            bearingFromPlace: degrees(GeoMath.bearing(from: place.coordinate, to: coordinate)))
    }

    private static func degrees(_ radians: Double) -> Double {
        let d = (radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    // MARK: Storage

    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        guard let url else { throw Failure(description: "Geography.sqlite isn't in the app bundle") }
        let opened = try SQLiteDatabase(url: url, readOnly: true)
        let version = try opened.prepare("SELECT value FROM meta WHERE key = 'schema_version'")
        guard try version.step(), version.text(0) == String(GeographySchema.version) else {
            throw Failure(description: "Geography.sqlite has a different schema version than this build expects")
        }
        database = opened
        return opened
    }

    private func places() throws -> [Place] {
        if let loadedPlaces { return loadedPlaces }
        let statement = try open().prepare("""
            SELECT id, wikidata, name, display_name, admin1, country, country_code, kind,
                latitude, longitude, scalerank, labelrank, min_zoom, population,
                urban_west, urban_south, urban_east, urban_north
            FROM places
            """)
        var result: [Place] = []
        result.reserveCapacity(8_000)
        while try statement.step() {
            let name = statement.text(2) ?? ""
            var urban: GeoBounds?
            if let west = statement.optionalDouble(14), let south = statement.optionalDouble(15),
               let east = statement.optionalDouble(16), let north = statement.optionalDouble(17) {
                urban = GeoBounds(south: south, west: west, north: north, east: east)
            }
            result.append(Place(
                id: statement.int(0), wikidata: statement.text(1), name: name, displayName: statement.text(3) ?? name,
                state: statement.text(4), country: statement.text(5), countryCode: statement.text(6),
                kind: statement.text(7) ?? "Populated place",
                coordinate: GeoCoordinate(latitude: statement.double(8), longitude: statement.double(9)),
                scaleRank: statement.int(10), labelRank: statement.int(11), minZoom: statement.double(12),
                population: statement.optionalInt(13), urbanArea: urban))
        }
        loadedPlaces = result
        return result
    }

    /// Every place's name with its country, for `sharesNameWithPlace`.
    private func placeNames() throws -> Set<String> {
        if let loadedPlaceNames { return loadedPlaceNames }
        let names = Set(try places().map { Self.nameKey($0.displayName, $0.countryCode) })
        loadedPlaceNames = names
        return names
    }

    private static func nameKey(_ name: String, _ countryCode: String?) -> String {
        "\(countryCode ?? "")|\(name.lowercased())"
    }

    private func geometry(id: Int) throws -> RegionGeometry {
        if let cached = geometryCache[id] { return cached }
        let statement = try open().prepare("SELECT geometry FROM regions WHERE id = ?").bind(id)
        guard try statement.step(), let geometry = RegionGeometry(encoded: statement.blob(0)) else {
            throw Failure(description: "Region \(id) has no readable geometry")
        }
        // Lookups follow the camera, so the same few regions come up again
        // and again; a small cache is enough.
        if geometryCache.count >= 64 { geometryCache.removeAll() }
        geometryCache[id] = geometry
        return geometry
    }
}

/// A latitude/longitude box. `west` greater than `east` means it crosses
/// the antimeridian.
struct GeoBounds: Codable, Equatable {
    var south: Double
    var west: Double
    var north: Double
    var east: Double

    func contains(_ c: GeoCoordinate) -> Bool {
        guard (south...north).contains(c.latitude) else { return false }
        return west <= east
            ? (west...east).contains(c.longitude)
            : c.longitude >= west || c.longitude <= east
    }
}
