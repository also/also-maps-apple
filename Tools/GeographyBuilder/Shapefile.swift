import Foundation

/// Reads the parts of the shapefile format that Natural Earth uses: point and
/// polygon shapes in a `.shp`, and attributes in a `.dbf`. It isn't a general
/// shapefile reader: Natural Earth is already in WGS84, so `.prj` is ignored,
/// and other shape types are rejected.
struct Shapefile {
    enum Shape {
        case null
        case point(longitude: Double, latitude: Double)
        /// Rings of (longitude, latitude), not grouped into outer boundaries
        /// and holes.
        case polygon(rings: [[SIMD2<Double>]])
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    let shapes: [Shape]
    let records: [[String: String]]
    /// The Natural Earth release, from the `.VERSION.txt` beside the files.
    let version: String?

    /// Reads `<base>.shp` and `<base>.dbf`, where `base` is a path with or
    /// without the `.shp` extension.
    init(base: String) throws {
        let base = base.hasSuffix(".shp") ? String(base.dropLast(4)) : base
        shapes = try Self.readShapes(Data(contentsOf: URL(fileURLWithPath: base + ".shp")))
        records = try Self.readRecords(Data(contentsOf: URL(fileURLWithPath: base + ".dbf")))
        version = (try? String(contentsOfFile: base + ".VERSION.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard shapes.count == records.count else {
            throw Failure(description: "\(base): \(shapes.count) shapes but \(records.count) records")
        }
    }

    private static func readShapes(_ data: Data) throws -> [Shape] {
        let bytes = [UInt8](data)
        func int32BE(_ o: Int) -> Int { Int(Int32(bitPattern: UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3]))) }
        func int32LE(_ o: Int) -> Int { Int(Int32(bitPattern: UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24)) }
        func double(_ o: Int) -> Double {
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(bytes[o + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: bits)
        }
        guard bytes.count >= 100, int32BE(0) == 9994 else { throw Failure(description: "Not a shapefile") }
        var shapes: [Shape] = []
        var offset = 100
        while offset + 8 <= bytes.count {
            let length = int32BE(offset + 4) * 2
            let content = offset + 8
            guard content + length <= bytes.count, length >= 4 else { throw Failure(description: "Truncated record at byte \(offset)") }
            switch int32LE(content) {
            case 0:
                shapes.append(.null)
            case 1:
                shapes.append(.point(longitude: double(content + 4), latitude: double(content + 12)))
            case 5:
                let partCount = int32LE(content + 36), pointCount = int32LE(content + 40)
                let parts = (0..<partCount).map { int32LE(content + 44 + 4 * $0) } + [pointCount]
                let points = content + 44 + 4 * partCount
                let rings = (0..<partCount).map { part in
                    (parts[part]..<parts[part + 1]).map { i in
                        SIMD2(double(points + 16 * i), double(points + 16 * i + 8))
                    }
                }
                shapes.append(.polygon(rings: rings))
            case let type:
                throw Failure(description: "Unsupported shape type \(type) at byte \(offset)")
            }
            offset = content + length
        }
        return shapes
    }

    /// Each record's fields by upper-cased name, trimmed of the spaces and
    /// NULs that pad them. Natural Earth's `.dbf` files are UTF-8.
    private static func readRecords(_ data: Data) throws -> [[String: String]] {
        let bytes = [UInt8](data)
        guard bytes.count >= 32 else { throw Failure(description: "Not a dBASE file") }
        let count = Int(UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24)
        let headerLength = Int(UInt16(bytes[8]) | UInt16(bytes[9]) << 8)
        let recordLength = Int(UInt16(bytes[10]) | UInt16(bytes[11]) << 8)
        var fields: [(name: String, offset: Int, length: Int)] = []
        var descriptor = 32, fieldOffset = 1
        while descriptor < headerLength, bytes[descriptor] != 0x0D {
            let raw = bytes[descriptor..<descriptor + 11].prefix { $0 != 0 }
            let length = Int(bytes[descriptor + 16])
            fields.append((String(decoding: raw, as: UTF8.self).uppercased(), fieldOffset, length))
            fieldOffset += length
            descriptor += 32
        }
        guard headerLength + count * recordLength <= bytes.count else { throw Failure(description: "Truncated dBASE file") }
        let padding = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0"))
        return (0..<count).map { record in
            let start = headerLength + record * recordLength
            var values: [String: String] = [:]
            for field in fields {
                let slice = bytes[start + field.offset..<start + field.offset + field.length]
                let value = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: padding)
                if !value.isEmpty { values[field.name] = value }
            }
            return values
        }
    }
}

extension Dictionary where Key == String, Value == String {
    /// A numeric field, or nil when it's empty or overflowed (dBASE writes
    /// asterisks for a number too wide for its field).
    func number(_ key: String) -> Double? {
        self[key].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
    }

    /// A text field, or nil for Natural Earth's placeholders for no value.
    func text(_ key: String) -> String? {
        guard let value = self[key], value != "-99", value != "-1" else { return nil }
        return value
    }
}
