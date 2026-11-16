import Foundation
import SQLite3

/// The layout of Geography.sqlite, shared by the app (Gazetteer) and the tool
/// that builds the file from Natural Earth (Tools/GeographyBuilder), so the
/// two can't disagree about it.
///
/// - `meta`: key/value pairs, including `schema_version` and each layer's
///   Natural Earth version.
/// - `places`: Natural Earth populated places, one row per point.
/// - `regions`: states and provinces (`layer` = `admin1`) and named waters
///   (`layer` = `marine`), each with its polygon rings as a blob.
/// - `region_rings`: an R*Tree with one entry per ring of each region, so a
///   lookup reads only the regions whose rings' boxes contain the point.
///   Boxes are per ring, not per region, because a region split at the
///   antimeridian would otherwise get a box spanning the whole globe.
/// - `names`: localized names by Natural Earth ID and language code, leaving
///   out any equal to the feature's own `name`.
enum GeographySchema {
    static let version = 1

    static let create = """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE places (
            id INTEGER PRIMARY KEY,
            wikidata TEXT,
            name TEXT NOT NULL,
            display_name TEXT NOT NULL,
            admin1 TEXT,
            country TEXT,
            country_code TEXT,
            kind TEXT NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            scalerank INTEGER NOT NULL,
            labelrank INTEGER NOT NULL,
            min_zoom REAL NOT NULL,
            population INTEGER,
            urban_west REAL, urban_south REAL, urban_east REAL, urban_north REAL
        );
        CREATE TABLE regions (
            id INTEGER PRIMARY KEY,
            layer TEXT NOT NULL,
            kind TEXT,
            wikidata TEXT,
            name TEXT NOT NULL,
            display_name TEXT NOT NULL,
            country TEXT,
            country_code TEXT,
            scalerank REAL,
            min_label REAL,
            geometry BLOB NOT NULL
        );
        CREATE VIRTUAL TABLE region_rings USING rtree(id, west, east, south, north, +region INTEGER);
        CREATE TABLE names (
            id INTEGER NOT NULL,
            language TEXT NOT NULL,
            name TEXT NOT NULL,
            PRIMARY KEY (id, language)
        ) WITHOUT ROWID;
        """
}

/// A region's polygon rings, as stored in `regions.geometry`: a ring count,
/// each ring's point count, then every point as Float32 longitude, latitude
/// (about 1 m precision), all little-endian.
///
/// Rings aren't grouped into outer boundaries and holes. Inside is decided
/// by the even–odd rule over all of a region's rings, which handles holes,
/// islands in lakes and multiple parts without knowing which ring is which.
struct RegionGeometry: Equatable {
    /// Each ring's points as (longitude, latitude), degrees. A ring's last
    /// point needn't repeat its first.
    var rings: [[SIMD2<Float>]]

    func encoded() -> Data {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(rings.count))
        for ring in rings { append(UInt32(ring.count)) }
        for ring in rings {
            for p in ring {
                append(p.x.bitPattern)
                append(p.y.bitPattern)
            }
        }
        return data
    }

    init(rings: [[SIMD2<Float>]]) {
        self.rings = rings
    }

    init?(encoded data: Data) {
        let words: [UInt32] = data.withUnsafeBytes { raw in
            guard raw.count % 4 == 0 else { return [] }
            return (0..<raw.count / 4).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        guard let ringCount = words.first.map(Int.init), words.count >= 1 + ringCount else { return nil }
        let counts = words[1...ringCount].map(Int.init)
        guard words.count == 1 + ringCount + 2 * counts.reduce(0, +) else { return nil }
        var index = 1 + ringCount
        rings = counts.map { count in
            defer { index += 2 * count }
            return (0..<count).map { i in
                SIMD2(Float(bitPattern: words[index + 2 * i]), Float(bitPattern: words[index + 2 * i + 1]))
            }
        }
    }

    /// Whether (longitude, latitude) is inside, by the even–odd rule.
    func contains(longitude: Double, latitude: Double) -> Bool {
        let x = Float(longitude), y = Float(latitude)
        var inside = false
        for ring in rings where ring.count >= 3 {
            var j = ring.count - 1
            for i in ring.indices {
                let a = ring[i], b = ring[j]
                if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
        }
        return inside
    }
}

/// A minimal SQLite connection: just what Geography.sqlite needs.
final class SQLiteDatabase {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private(set) var handle: OpaquePointer?

    /// Opens `url`. Read-only opens are marked immutable, so SQLite takes no
    /// locks and needs no journal: right for a file inside the app bundle.
    init(url: URL, readOnly: Bool) throws {
        let flags: Int32
        let path: String
        if readOnly {
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.scheme = "file"
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            path = components.string!
        } else {
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
            path = url.path
        }
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close(handle)
            handle = nil
            throw Failure(description: "Opening \(url.lastPathComponent): \(message)")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw Failure(description: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(description: "\(String(cString: sqlite3_errmsg(handle))) in: \(sql)")
        }
        return Statement(statement, database: self)
    }

    final class Statement {
        private let statement: OpaquePointer
        private let database: SQLiteDatabase
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        fileprivate init(_ statement: OpaquePointer, database: SQLiteDatabase) {
            self.statement = statement
            self.database = database
        }

        deinit {
            sqlite3_finalize(statement)
        }

        /// Binds `values` to parameters 1, 2, … after resetting the statement.
        @discardableResult
        func bind(_ values: Any?...) -> Statement {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            for (offset, value) in values.enumerated() {
                let i = Int32(offset + 1)
                switch value {
                case nil: sqlite3_bind_null(statement, i)
                case let v as Int: sqlite3_bind_int64(statement, i, Int64(v))
                case let v as Int64: sqlite3_bind_int64(statement, i, v)
                case let v as Double: sqlite3_bind_double(statement, i, v)
                case let v as String: sqlite3_bind_text(statement, i, v, -1, Self.transient)
                case let v as Data:
                    _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32($0.count), Self.transient) }
                default: preconditionFailure("Unsupported SQLite value \(String(describing: value))")
                }
            }
            return self
        }

        /// Steps once: true with a row ready to read, false when done.
        func step() throws -> Bool {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw Failure(description: String(cString: sqlite3_errmsg(database.handle)))
            }
        }

        /// Runs a statement that returns no rows.
        func run() throws {
            while try step() {}
        }

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
        func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func blob(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }
}
