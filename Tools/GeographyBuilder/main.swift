import Foundation

// Builds Geography.sqlite from Natural Earth shapefiles. Scripts/build_geography.sh
// compiles and runs it during app builds, with the files pinned in
// Scripts/natural_earth.txt.

let usage = """
    usage: GeographyBuilder --places <ne_10m_populated_places> \
    --admin1 <ne_10m_admin_1_states_provinces> \
    --marine <ne_10m_geography_marine_polys> \
    --output <Geography.sqlite> [--tolerance <meters>]
    """

var arguments: [String: String] = [:]
var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let key = iterator.next() {
    guard key.hasPrefix("--"), let value = iterator.next() else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
    arguments[String(key.dropFirst(2))] = value
}
guard let placesPath = arguments["places"], let admin1Path = arguments["admin1"],
      let marinePath = arguments["marine"], let outputPath = arguments["output"] else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
let tolerance = arguments["tolerance"].flatMap(Double.init) ?? 500

/// Words Wikidata's English labels (`NAME_EN`) sometimes add after a name.
let typeSuffixes: Set<String> = [
    "atoll", "borough", "city", "comarca", "commune", "county", "department",
    "district", "governorate", "municipality", "oblast", "parish", "prefecture",
    "province", "raion", "region", "shire", "town", "township", "village",
]

/// The name used in English phrases: `NAME_EN`, which has the familiar
/// English forms (Tobruk, not Tubruq), unless it's just `NAME` plus a type
/// word ("Davao City", "Sunshine Coast Region"), where `NAME` reads better.
func displayName(name: String, english: String?) -> String {
    guard let english, english != name else { return name }
    if english.hasPrefix(name + " ") {
        let rest = english.dropFirst(name.count + 1).lowercased()
        if typeSuffixes.contains(rest) { return name }
    }
    return english
}

/// Language codes for Natural Earth's `NAME_xx` columns.
func language(forField field: String) -> String? {
    guard field.hasPrefix("NAME_") else { return nil }
    let code = field.dropFirst(5).lowercased()
    switch code {
    case "zh": return "zh-Hans"
    case "zht": return "zh-Hant"
    case "len", "alt", "local": return nil
    default: return code.count == 2 ? code : nil
    }
}

func run() throws {
    let output = URL(fileURLWithPath: outputPath)
    let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).building")
    try? FileManager.default.removeItem(at: temporary)

    let db = try SQLiteDatabase(url: temporary, readOnly: false)
    try db.execute("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA page_size = 4096;")
    try db.execute(GeographySchema.create)
    try db.execute("BEGIN")

    let insertName = try db.prepare("INSERT OR IGNORE INTO names (id, language, name) VALUES (?, ?, ?)")
    var nameCount = 0
    func insertNames(id: Int, base: String, record: [String: String]) throws {
        for (field, value) in record {
            guard let language = language(forField: field), value != base else { continue }
            try insertName.bind(id, language, value).run()
            nameCount += 1
        }
    }

    // Populated places.
    let places = try Shapefile(base: placesPath)
    let insertPlace = try db.prepare("""
        INSERT INTO places (id, wikidata, name, display_name, admin1, country, country_code, kind,
            latitude, longitude, scalerank, labelrank, min_zoom, population,
            urban_west, urban_south, urban_east, urban_north)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
    var placeCount = 0
    for (shape, r) in zip(places.shapes, places.records) {
        guard case let .point(longitude, latitude) = shape,
              let id = r.number("NE_ID").map({ Int($0) }), let name = r["NAME"] else { continue }
        var urban: [Double?] = [nil, nil, nil, nil]
        if let west = r.number("MAX_BBXMIN"), let east = r.number("MAX_BBXMAX"),
           let south = r.number("MAX_BBYMIN"), let north = r.number("MAX_BBYMAX"),
           west < east, south < north,
           (west...east).contains(longitude), (south...north).contains(latitude) {
            urban = [west, south, east, north]
        }
        try insertPlace.bind(
            id, r.text("WIKIDATAID"), name, displayName(name: name, english: r["NAME_EN"]),
            r.text("ADM1NAME"), r.text("ADM0NAME"), r.text("ISO_A2"), r["FEATURECLA"] ?? "Populated place",
            latitude, longitude,
            Int(r.number("SCALERANK") ?? 10), Int(r.number("LABELRANK") ?? 10), r.number("MIN_ZOOM") ?? 10,
            r.number("POP_MAX").map { Int($0) },
            urban[0], urban[1], urban[2], urban[3]
        ).run()
        try insertNames(id: id, base: name, record: r)
        placeCount += 1
    }

    // Regions: states and provinces, and named waters.
    let insertRegion = try db.prepare("""
        INSERT INTO regions (id, layer, kind, wikidata, name, display_name, country, country_code,
            scalerank, min_label, geometry)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
    let insertRing = try db.prepare("INSERT INTO region_rings (west, east, south, north, region) VALUES (?, ?, ?, ?, ?)")
    var pointsBefore = 0, pointsAfter = 0, regionCount = 0

    func addRegions(_ file: Shapefile, layer: String, kindField: String, hasCountry: Bool) throws {
        // A feature can appear as more than one record with the same ID
        // (the Great Barrier Reef does, in marine 5.1.0): one region, with
        // the records' rings together.
        var order: [Int] = []
        var features: [Int: (record: [String: String], rings: [[SIMD2<Double>]])] = [:]
        for (shape, r) in zip(file.shapes, file.records) {
            guard case let .polygon(rings) = shape, let id = r.number("NE_ID").map({ Int($0) }) else { continue }
            if features[id] == nil { order.append(id) }
            features[id, default: (r, [])].rings += rings
        }
        for id in order {
            let (r, rings) = features[id]!
            guard let name = r["NAME"] else { continue }
            let simplified = rings.map { simplifiedRing($0, tolerance: tolerance) }
            pointsBefore += rings.reduce(0) { $0 + $1.count }
            pointsAfter += simplified.reduce(0) { $0 + $1.count }
            let geometry = RegionGeometry(rings: simplified.map { $0.map { SIMD2<Float>(Float($0.x), Float($0.y)) } })
            try insertRegion.bind(
                id, layer, r.text(kindField), r.text("WIKIDATAID"), name, displayName(name: name, english: r["NAME_EN"]),
                hasCountry ? r.text("ADMIN") : nil, hasCountry ? r.text("ISO_A2") : nil,
                r.number("SCALERANK"), r.number("MIN_LABEL"), geometry.encoded()
            ).run()
            for ring in geometry.rings where !ring.isEmpty {
                let xs = ring.map(\.x), ys = ring.map(\.y)
                try insertRing.bind(Double(xs.min()!), Double(xs.max()!), Double(ys.min()!), Double(ys.max()!), id).run()
            }
            try insertNames(id: id, base: name, record: r)
            regionCount += 1
        }
    }
    let admin1 = try Shapefile(base: admin1Path)
    try addRegions(admin1, layer: "admin1", kindField: "TYPE_EN", hasCountry: true)
    let marine = try Shapefile(base: marinePath)
    try addRegions(marine, layer: "marine", kindField: "FEATURECLA", hasCountry: false)

    let insertMeta = try db.prepare("INSERT INTO meta (key, value) VALUES (?, ?)")
    for (key, value) in [
        ("schema_version", String(GeographySchema.version)),
        ("ne_populated_places", places.version ?? "unknown"),
        ("ne_admin_1_states_provinces", admin1.version ?? "unknown"),
        ("ne_geography_marine_polys", marine.version ?? "unknown"),
        ("simplify_tolerance_m", String(tolerance)),
    ] {
        try insertMeta.bind(key, value).run()
    }
    try db.execute("COMMIT")
    try db.execute("VACUUM")

    try? FileManager.default.removeItem(at: output)
    try FileManager.default.moveItem(at: temporary, to: output)
    let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
    print("""
        \(placeCount) places, \(regionCount) regions, \(nameCount) localized names
        polygon points: \(pointsBefore) → \(pointsAfter) at \(tolerance) m
        wrote \(output.path) (\(size / 1024) KB)
        """)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("GeographyBuilder: \(error)\n".utf8))
    exit(1)
}
