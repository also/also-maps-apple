import Foundation
import simd
import Testing

struct SolarPositionTests {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))!
    }

    /// The worked example in Reda and Andreas, "Solar Position Algorithm for
    /// Solar Radiation Applications", NREL/TP-560-34302 (revised 2008),
    /// table A5.1: 17 October 2003, 12:30:30 at UTC−7, at 39.742476° N,
    /// 105.1786° W. SPA gives a topocentric zenith of 50.11162° (refracted
    /// for 820 mbar and 11 °C), azimuth 194.34024°, geocentric declination
    /// −9.31434° and an equation of time of 14.641503 minutes. NOAA's
    /// equations are simpler than SPA, so agreement to 0.01° is the claim.
    @Test
    func matchesTheNRELSolarPositionAlgorithmExample() {
        let sun = SolarPosition(date: utc(2003, 10, 17, 19, 30, 30), latitude: 39.742476, longitude: -105.1786)
        #expect(abs((90 - sun.apparentElevation) - 50.11162) < 0.01)
        #expect(abs(sun.azimuth - 194.34024) < 0.01)
        #expect(abs(sun.declination - -9.31434) < 0.01)
        #expect(abs(sun.equationOfTime - 14.641503) < 0.02)
    }

    /// At a solstice the declination is ± the obliquity, 23.436° in 2024.
    /// Solstice instants from the US Naval Observatory's "Earth's Seasons"
    /// table for 2024: 20 June 20:51 UTC and 21 December 09:20 UTC.
    @Test
    func declinationIsTheObliquityAtTheSolstices() {
        let june = SolarPosition(date: utc(2024, 6, 20, 20, 51), latitude: 0, longitude: 0)
        let december = SolarPosition(date: utc(2024, 12, 21, 9, 20), latitude: 0, longitude: 0)
        #expect(abs(june.declination - 23.436) < 0.01)
        #expect(abs(december.declination - -23.436) < 0.01)
    }

    /// Geometry rather than published numbers: at local solar noon the sun
    /// is due south (north of the tropics) at 90° − latitude + declination.
    @Test
    func noonElevationFollowsFromLatitudeAndDeclination() {
        // London, 21 June 2024: solar noon is about 12:02 UTC at 0.13° W.
        let path = SolarPosition.dayPath(containing: utc(2024, 6, 21, 12, 0), timeZone: TimeZone(identifier: "UTC")!,
                                         latitude: 51.5, longitude: -0.13, step: 30)
        let noon = path.max { $0.position.elevation < $1.position.elevation }!.position
        #expect(abs(noon.elevation - (90 - 51.5 + noon.declination)) < 0.05)
        #expect(abs(noon.azimuth - 180) < 1)
    }

    @Test
    func theSunNeverRisesInTromsoAtTheDecemberSolstice() {
        let path = SolarPosition.dayPath(containing: utc(2024, 12, 21, 12, 0), timeZone: TimeZone(identifier: "Europe/Oslo")!,
                                         latitude: 69.65, longitude: 18.96)
        #expect(path.allSatisfy { $0.position.apparentElevation < 0 })
    }

    @Test
    func directionsUseTheAnchorFramesAxes() {
        let east = SolarPosition(azimuth: 90, elevation: 0, declination: 0, equationOfTime: 0).anchorFrame
        let south = SolarPosition(azimuth: 180, elevation: 0, declination: 0, equationOfTime: 0).anchorFrame
        let zenith = SolarPosition(azimuth: 0, elevation: 90, declination: 0, equationOfTime: 0).anchorFrame
        #expect(simd_distance(east, [1, 0, 0]) < 1e-9)
        #expect(simd_distance(south, [0, 0, 1]) < 1e-9)
        #expect(simd_distance(zenith, [0, 1, 0]) < 1e-9)
    }

    /// The path covers the place's calendar day, including the short day
    /// when the clocks go forward.
    @Test
    func dayPathSpansTheLocalDay() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let ordinary = SolarPosition.dayPath(containing: utc(2024, 3, 9, 17, 0), timeZone: newYork,
                                             latitude: 40.7, longitude: -74)
        let springForward = SolarPosition.dayPath(containing: utc(2024, 3, 10, 17, 0), timeZone: newYork,
                                                  latitude: 40.7, longitude: -74)
        #expect(ordinary.count == 24 * 6 + 1)
        #expect(springForward.count == 23 * 6 + 1)
        #expect(ordinary.first?.date == utc(2024, 3, 9, 5, 0))
    }

    @Test
    func refractionLiftsTheSunMostAtTheHorizon() {
        #expect(abs(SolarPosition.refraction(elevation: 0) - 1735.0 / 3600) < 1e-9)
        #expect(SolarPosition.refraction(elevation: 45) < 0.02)
        #expect(SolarPosition.refraction(elevation: 89) == 0)
    }
}
