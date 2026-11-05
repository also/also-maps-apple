import Foundation
import simd

/// Where the sun is in the sky for a place and instant, from NOAA's solar
/// position equations (the "General Solar Position Calculations" behind
/// NOAA's online solar calculator, after Meeus, Astronomical Algorithms).
/// Good to about 0.01° between 1800 and 2100, which is far finer than a
/// shadow map can show. Pure Foundation, for the sun and shadow study
/// (notes/clay-and-sun.md).
struct SolarPosition: Equatable {
    /// Degrees clockwise from true north.
    var azimuth: Double
    /// Degrees above the geometric horizon, without refraction: the
    /// direction light actually arrives from, for lighting and shadows.
    var elevation: Double
    /// Degrees; positive north of the equator.
    var declination: Double
    /// Apparent minus mean solar time, minutes.
    var equationOfTime: Double

    /// Elevation as seen, with NOAA's standard-atmosphere refraction: what a
    /// published table or the NOAA calculator lists. Near the horizon the
    /// sun looks about half a degree higher than it geometrically is.
    var apparentElevation: Double {
        elevation + Self.refraction(elevation: elevation)
    }

    /// Unit vector toward the sun in east, north, up components.
    var enu: SIMD3<Double> {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        return SIMD3(sin(a) * cos(e), cos(a) * cos(e), sin(e))
    }

    /// Unit vector toward the sun in the anchor frame's axes (x east, y up,
    /// z south), at the place it was computed for.
    var anchorFrame: SIMD3<Double> {
        let v = enu
        return SIMD3(v.x, v.z, -v.y)
    }

    init(azimuth: Double, elevation: Double, declination: Double, equationOfTime: Double) {
        self.azimuth = azimuth
        self.elevation = elevation
        self.declination = declination
        self.equationOfTime = equationOfTime
    }

    /// The sun at `date` from latitude and longitude in degrees (east
    /// positive). Height above the ground and parallax are ignored; both
    /// move the sun by thousandths of a degree.
    init(date: Date, latitude: Double, longitude: Double) {
        let degrees = Double.pi / 180
        // Julian day (UT) and Julian centuries since J2000.0. NOAA uses UT
        // throughout; the difference to terrestrial time (about a minute)
        // moves the sun along the ecliptic by under 0.001°.
        let julianDay = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545) / 36_525

        let meanLongitude = (280.46646 + t * (36000.76983 + t * 0.0003032))
            .truncatingRemainder(dividingBy: 360)
        let meanAnomaly = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let m = meanAnomaly * degrees
        let centre = sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m) * (0.019993 - 0.000101 * t)
            + sin(3 * m) * 0.000289
        let omega = (125.04 - 1934.136 * t) * degrees
        let apparentLongitude = (meanLongitude + centre - 0.00569 - 0.00478 * sin(omega)) * degrees
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = (meanObliquity + 0.00256 * cos(omega)) * degrees
        let declination = asin(sin(obliquity) * sin(apparentLongitude))

        let y = pow(tan(obliquity / 2), 2)
        let l0 = meanLongitude * degrees
        let equationOfTime = 4 / degrees * (y * sin(2 * l0) - 2 * eccentricity * sin(m)
            + 4 * eccentricity * y * sin(m) * cos(2 * l0)
            - 0.5 * y * y * sin(4 * l0) - 1.25 * eccentricity * eccentricity * sin(2 * m))

        // True solar time at the place, then the hour angle: 0 at local
        // solar noon, positive in the afternoon.
        let minutesUT = (date.timeIntervalSince1970 / 60).truncatingRemainder(dividingBy: 1440)
        var solarMinutes = (minutesUT + equationOfTime + 4 * longitude).truncatingRemainder(dividingBy: 1440)
        if solarMinutes < 0 { solarMinutes += 1440 }
        let hourAngle = (solarMinutes / 4 - 180) * degrees

        // The direction to the sun in the place's east, north, up frame,
        // written out rather than through NOAA's acos form, so azimuth has
        // no branch and stays well-conditioned at the zenith and poles.
        let phi = latitude * degrees
        let east = -cos(declination) * sin(hourAngle)
        let north = sin(declination) * cos(phi) - cos(declination) * cos(hourAngle) * sin(phi)
        let up = sin(declination) * sin(phi) + cos(declination) * cos(hourAngle) * cos(phi)
        var azimuth = atan2(east, north) / degrees
        if azimuth < 0 { azimuth += 360 }
        self.init(azimuth: azimuth, elevation: asin(min(max(up, -1), 1)) / degrees,
                  declination: declination / degrees, equationOfTime: equationOfTime)
    }

    /// NOAA's atmospheric refraction correction, degrees, for a geometric
    /// elevation in degrees.
    static func refraction(elevation: Double) -> Double {
        let arcseconds: Double
        if elevation > 85 {
            arcseconds = 0
        } else if elevation > 5 {
            let t = tan(elevation * .pi / 180)
            arcseconds = 58.1 / t - 0.07 / pow(t, 3) + 0.000086 / pow(t, 5)
        } else if elevation > -0.575 {
            let e = elevation
            arcseconds = 1735 + e * (-518.2 + e * (103.4 + e * (-12.79 + e * 0.711)))
        } else {
            arcseconds = -20.772 / tan(elevation * .pi / 180)
        }
        return arcseconds / 3600
    }

    /// The sun every `step` seconds through the calendar day containing
    /// `date` in `timeZone`, from its midnight to the next (23 or 25 hours
    /// on a daylight-saving change). For drawing the day's path.
    static func dayPath(containing date: Date, timeZone: TimeZone, latitude: Double, longitude: Double,
                        step: TimeInterval = 600) -> [(date: Date, position: SolarPosition)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        guard step > 0, let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: step).map {
            let instant = Date(timeIntervalSince1970: $0)
            return (instant, SolarPosition(date: instant, latitude: latitude, longitude: longitude))
        }
    }
}
