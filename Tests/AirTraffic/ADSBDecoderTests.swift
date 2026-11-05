import Foundation
import Testing

/// A small response in adsb.lol's v2 format, written by hand from readsb's
/// README-json.md and adsb.lol's response model, not captured.
private let sample = Data("""
{"ac": [
  {"hex": "A1B2C3", "type": "adsb_icao", "flight": "UAL123  ", "alt_baro": 3000, "alt_geom": 2900,
   "gs": 160.0, "track": 280.0, "baro_rate": -704, "geom_rate": -768, "category": "A3",
   "lat": 37.6, "lon": -122.3, "seen_pos": 1.2, "seen": 0.5, "messages": 100, "mlat": [], "tisb": [], "rssi": -20.1},
  {"hex": "a00002", "alt_baro": 6000, "alt_geom": 6100, "lat": 37.65, "lon": -122.25, "seen_pos": 0.4,
   "messages": 1, "mlat": [], "tisb": [], "rssi": -25, "seen": 0.1},
  {"hex": "abcdef", "alt_baro": "ground", "gs": 12.3, "track": 90, "lat": 37.61, "lon": -122.38,
   "seen_pos": 3, "category": "A3", "messages": 5, "mlat": [], "tisb": [], "rssi": -30, "seen": 1},
  {"hex": "c0ffee", "flight": "        ", "alt_baro": 5000, "baro_rate": 1200, "gs": 200, "track": 0,
   "lat": 37.7, "lon": -122.2, "seen_pos": 2, "messages": 9, "mlat": [], "tisb": [], "rssi": -9, "seen": 2},
  {"hex": "dead00", "alt_baro": 10000, "messages": 1, "mlat": [], "tisb": [], "rssi": -9, "seen": 1},
  {"hex": "a1d000", "alt_baro": 10000, "alt_geom": 10100, "lat": 37.0, "lon": -122.0, "seen_pos": 45,
   "messages": 1, "mlat": [], "tisb": [], "rssi": -9, "seen": 1},
  {"hex": "c1c1c1", "alt_baro": "ground", "lat": 37.62, "lon": -122.37, "category": "C1", "seen_pos": 1,
   "messages": 1, "mlat": [], "tisb": [], "rssi": -9, "seen": 1},
  {"hex": "bad001", "alt_baro": 2000, "lat": "north", "lon": -122.1, "seen_pos": 1},
  {"no_hex": true}
 ],
 "ctime": 1793000000000, "msg": "No error", "now": 1793000000123, "ptime": 1, "total": 9}
""".utf8)

struct ADSBDecoderTests {
    private func decoded() throws -> [String: AircraftReport] {
        let snapshot = try ADSBDecoder.decode(sample)
        return Dictionary(uniqueKeysWithValues: snapshot.reports.map { ($0.id, $0) })
    }

    @Test func keepsOnlyAircraftWithRecentPositions() throws {
        // No position, too old, a surface vehicle, a broken latitude and no
        // hex are all skipped, without failing the rest.
        #expect(Set(try decoded().keys) == ["a1b2c3", "a00002", "abcdef", "c0ffee"])
    }

    @Test func convertsUnitsAndPrefersGeometricAltitude() throws {
        let report = try #require(try decoded()["a1b2c3"])
        #expect(report.callsign == "UAL123")
        #expect(report.heightSource == .geometric)
        #expect(abs(report.height! - 2900 * 0.3048) < 1e-9)
        #expect(abs(report.groundSpeed! - 160 * 1852 / 3600) < 1e-9)
        #expect(abs(report.track! - 280 * Double.pi / 180) < 1e-12)
        // The geometric rate goes with the geometric altitude.
        #expect(abs(report.verticalRate! - -768 * 0.3048 / 60) < 1e-9)
        #expect(report.positionAge == 1.2)
        #expect(!report.onGround)
    }

    @Test func groundWithoutGeometricAltitudeTakesTheHostsGround() throws {
        let report = try #require(try decoded()["abcdef"])
        #expect(report.onGround)
        #expect(report.height == nil)
        #expect(report.heightSource == .ground)
        #expect(report.verticalRate == 0)
    }

    @Test func barometricOnlyIsMovedByItsNeighboursOffset() throws {
        let report = try #require(try decoded()["c0ffee"])
        // Neighbours within 3000 ft of 5000 ft: −100 ft at 3000, +100 ft at
        // 6000. (The stale one at 10,000 ft is too far above to count.)
        #expect(report.heightSource == .barometricAdjusted(offset: 0))
        #expect(abs(report.height! - 5000 * 0.3048) < 1e-9)
        #expect(report.callsign == nil)
        #expect(abs(report.verticalRate! - 1200 * 0.3048 / 60) < 1e-9)
    }

    @Test func serverTimeIsInMillisecondsFromTheV2API() throws {
        let snapshot = try ADSBDecoder.decode(sample)
        #expect(abs(snapshot.serverTime!.timeIntervalSince1970 - 1_793_000_000.123) < 1e-3)
    }

    @Test func readsAircraftJSONToo() throws {
        let local = Data("""
            {"now": 1793000000.5, "messages": 1, "aircraft": [
              {"hex": "abc123", "alt_baro": 1000, "lat": 1, "lon": 2, "seen_pos": 0}]}
            """.utf8)
        let snapshot = try ADSBDecoder.decode(local)
        #expect(snapshot.reports.map(\.id) == ["abc123"])
        // Only one aircraft, so no offset to apply.
        #expect(snapshot.reports[0].heightSource == .barometric)
        #expect(snapshot.serverTime == Date(timeIntervalSince1970: 1_793_000_000.5))
    }

    @Test func rejectsWhatIsntAircraftJSON() {
        #expect(throws: (any Error).self) { try ADSBDecoder.decode(Data(#"{"msg": "Unauthorized"}"#.utf8)) }
        #expect(throws: (any Error).self) { try ADSBDecoder.decode(Data("<html>".utf8)) }
    }

    @Test func offsetNeedsTwoNeighboursOrThreeInAll() {
        let two = [(barometric: 1000.0, offset: 10.0), (barometric: 1200.0, offset: 20.0)]
        #expect(ADSBDecoder.geometricOffset(at: 1100, among: two) == 15)
        // Both far away, and only two in all: no estimate.
        #expect(ADSBDecoder.geometricOffset(at: 9000, among: two) == nil)
        let three = two + [(barometric: 9000.0, offset: 90.0)]
        // One near isn't enough; the median of all three is used.
        #expect(ADSBDecoder.geometricOffset(at: 9500, among: three) == 20)
    }
}
