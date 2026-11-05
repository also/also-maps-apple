import Foundation

/// One aircraft's latest position report, in SI units, with its height
/// resolved to metres above the WGS84 ellipsoid (the height Google's tiles
/// use) as well as the report allows. See notes/live-air-traffic.md for what
/// the source fields mean and how far off the height can be.
struct AircraftReport: Equatable {
    /// The 24-bit ICAO address as lower-case hex; "~" first for a non-ICAO
    /// address (TIS-B and the like).
    var id: String
    /// Callsign or registration, trimmed; nil if none was received.
    var callsign: String?
    var coordinate: GeoCoordinate
    /// Metres above the ellipsoid, or nil on the ground with no geometric
    /// altitude, where the host's ground estimate is used instead.
    var height: Double?
    var heightSource: HeightSource
    var onGround: Bool
    /// Metres per second over the ground.
    var groundSpeed: Double?
    /// Radians clockwise from true north: the direction of travel, not the
    /// way the nose points.
    var track: Double?
    /// Metres per second, positive climbing.
    var verticalRate: Double?
    /// The emitter category, "A0" to "D7".
    var category: String?
    /// How long before the response the position was measured, seconds.
    var positionAge: Double

    enum HeightSource: Equatable {
        /// GNSS height, which ADS-B reports above the ellipsoid.
        case geometric
        /// Pressure altitude moved by how far geometric altitude sits above
        /// it for nearby aircraft in the same response: mostly the day's
        /// weather, which is shared across an area.
        case barometricAdjusted(offset: Double)
        /// Pressure altitude as is: off by the weather (often 100 m or more)
        /// and by the geoid (tens of metres).
        case barometric
        /// On the ground with no geometric altitude.
        case ground
    }
}

/// A decoded response: the reports in it, and the server's clock when it
/// was made, for logs. Report ages are relative to that time, so reports are
/// placed on the device's clock by their age rather than by the server's.
struct AirTrafficSnapshot: Equatable {
    var reports: [AircraftReport]
    var serverTime: Date?
}

/// Decodes readsb's aircraft JSON: adsb.lol's v2 API (the ADS-B Exchange v2
/// format, readsb's "jv2": aircraft under `ac`, `now` in milliseconds), and
/// a local readsb's aircraft.json (`aircraft`, `now` in seconds). Fields are
/// as readsb's README-json.md documents them: feet, knots, feet per minute,
/// degrees. Aircraft this can't use are skipped, not fatal.
enum ADSBDecoder {
    static let metresPerFoot = 0.3048
    static let metresPerSecondPerKnot = 1852.0 / 3600
    static let metresPerSecondPerFootPerMinute = 0.3048 / 60

    /// Positions older than this are dropped: readsb keeps an aircraft for a
    /// while after its last position, and a stale one would be dead
    /// reckoned a long way.
    static let maximumPositionAge = 30.0

    /// Barometric altitudes within this of an aircraft's (metres) count as
    /// nearby when estimating its geometric offset; the offset grows with
    /// altitude, so aircraft far above or below say less about it.
    static let offsetNeighbourhood = 3000 * metresPerFoot

    enum DecodingFailure: Error { case notAircraftJSON }

    static func decode(_ data: Data) throws -> AirTrafficSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let aircraft = response.ac ?? response.aircraft else { throw DecodingFailure.notAircraftJSON }
        let raws = aircraft.compactMap(\.value)
        let offsets = geometricOffsets(raws)
        let reports = raws.compactMap { report(from: $0, offsets: offsets) }
        let serverTime = response.now.map { now in
            // Milliseconds from the v2 API, seconds from aircraft.json; any
            // time this century is under 1e10 seconds.
            Date(timeIntervalSince1970: now > 1e11 ? now / 1000 : now)
        }
        return AirTrafficSnapshot(reports: reports, serverTime: serverTime)
    }

    // MARK: Heights

    /// For every airborne aircraft reporting both altitudes: its barometric
    /// altitude and how far its geometric altitude is above that, metres.
    private static func geometricOffsets(_ raws: [Raw]) -> [(barometric: Double, offset: Double)] {
        raws.compactMap { raw in
            guard case let .feet(baro)? = raw.altitudeBarometric, let geom = raw.altitudeGeometric else { return nil }
            return (baro * metresPerFoot, (geom - baro) * metresPerFoot)
        }
    }

    /// How far geometric altitude sits above barometric for aircraft near
    /// `barometric` metres: the median of those within the neighbourhood if
    /// there are two, else of all of them if there are three, else nil.
    static func geometricOffset(at barometric: Double,
                                among offsets: [(barometric: Double, offset: Double)]) -> Double? {
        let near = offsets.filter { abs($0.barometric - barometric) <= offsetNeighbourhood }.map(\.offset)
        if near.count >= 2 { return median(near) }
        if offsets.count >= 3 { return median(offsets.map(\.offset)) }
        return nil
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func report(from raw: Raw, offsets: [(barometric: Double, offset: Double)]) -> AircraftReport? {
        guard let latitude = raw.lat, let longitude = raw.lon,
              (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        let age = raw.seenPos ?? raw.seen ?? 0
        guard age <= maximumPositionAge else { return nil }
        // Category C is surface vehicles and obstacles, not aircraft.
        if let category = raw.category, category.hasPrefix("C") { return nil }

        let onGround = raw.altitudeBarometric == .ground
        let height: Double?
        let source: AircraftReport.HeightSource
        var usesGeometric = false
        if let geom = raw.altitudeGeometric {
            height = geom * metresPerFoot
            source = .geometric
            usesGeometric = true
        } else if case let .feet(baro)? = raw.altitudeBarometric {
            let barometric = baro * metresPerFoot
            if let offset = geometricOffset(at: barometric, among: offsets) {
                height = barometric + offset
                source = .barometricAdjusted(offset: offset)
            } else {
                height = barometric
                source = .barometric
            }
        } else if onGround {
            height = nil
            source = .ground
        } else {
            return nil
        }

        // The vertical rate that matches the altitude used, else the other.
        let feetPerMinute = usesGeometric ? (raw.geomRate ?? raw.baroRate) : (raw.baroRate ?? raw.geomRate)
        let callsign = raw.flight?.trimmingCharacters(in: .whitespaces)
        return AircraftReport(
            id: raw.hex.lowercased(),
            callsign: callsign?.isEmpty == false ? callsign : nil,
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            height: height,
            heightSource: source,
            onGround: onGround,
            groundSpeed: raw.gs.map { $0 * metresPerSecondPerKnot },
            track: raw.track.map { $0 * .pi / 180 },
            verticalRate: onGround ? 0 : feetPerMinute.map { $0 * metresPerSecondPerFootPerMinute },
            category: raw.category,
            positionAge: max(age, 0))
    }

    // MARK: JSON

    private struct Response: Decodable {
        var ac: [Lossy<Raw>]?
        var aircraft: [Lossy<Raw>]?
        var now: Double?
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) { value = try? Value(from: decoder) }
    }

    /// `alt_baro`: feet, or the string "ground".
    enum BarometricAltitude: Decodable, Equatable {
        case feet(Double)
        case ground

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let feet = try? c.decode(Double.self) {
                self = .feet(feet)
            } else if try c.decode(String.self) == "ground" {
                self = .ground
            } else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "alt_baro is neither feet nor \"ground\"")
            }
        }
    }

    private struct Raw: Decodable {
        var hex: String
        var flight: String?
        var lat: Double?
        var lon: Double?
        var altitudeBarometric: BarometricAltitude?
        var altitudeGeometric: Double?
        var gs: Double?
        var track: Double?
        var baroRate: Double?
        var geomRate: Double?
        var seenPos: Double?
        var seen: Double?
        var category: String?

        private enum CodingKeys: String, CodingKey {
            case hex, flight, lat, lon, gs, track, seen, category
            case altitudeBarometric = "alt_baro"
            case altitudeGeometric = "alt_geom"
            case baroRate = "baro_rate"
            case geomRate = "geom_rate"
            case seenPos = "seen_pos"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hex = try c.decode(String.self, forKey: .hex)
            // Optional fields that don't parse are dropped, not fatal.
            flight = try? c.decodeIfPresent(String.self, forKey: .flight)
            lat = try? c.decodeIfPresent(Double.self, forKey: .lat)
            lon = try? c.decodeIfPresent(Double.self, forKey: .lon)
            altitudeBarometric = try? c.decodeIfPresent(BarometricAltitude.self, forKey: .altitudeBarometric)
            altitudeGeometric = try? c.decodeIfPresent(Double.self, forKey: .altitudeGeometric)
            gs = try? c.decodeIfPresent(Double.self, forKey: .gs)
            track = try? c.decodeIfPresent(Double.self, forKey: .track)
            baroRate = try? c.decodeIfPresent(Double.self, forKey: .baroRate)
            geomRate = try? c.decodeIfPresent(Double.self, forKey: .geomRate)
            seenPos = try? c.decodeIfPresent(Double.self, forKey: .seenPos)
            seen = try? c.decodeIfPresent(Double.self, forKey: .seen)
            category = try? c.decodeIfPresent(String.self, forKey: .category)
        }
    }
}
