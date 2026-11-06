import Foundation
import simd

/// The sun's position from a place and a time: the standard low-precision
/// solar maths (the Astronomical Almanac's, good to about 0.01° for a few
/// decades around 2000), with no atmospheric refraction. Enough for lighting
/// and shadow direction; not for astronomy.
enum MetalSun {
    struct Position: Equatable {
        /// Degrees above the horizon (negative at night).
        var elevation: Double
        /// Degrees clockwise from true north: 90 is east, 180 south.
        var azimuth: Double

        /// A unit vector toward the sun in a local east-north-up frame.
        var eastNorthUp: SIMD3<Double> {
            let elevation = elevation * .pi / 180, azimuth = azimuth * .pi / 180
            return SIMD3(cos(elevation) * sin(azimuth), cos(elevation) * cos(azimuth), sin(elevation))
        }
    }

    /// Where the sun is at `latitude` and `longitude` (degrees, east
    /// positive) at `date`.
    static func position(latitude: Double, longitude: Double, date: Date) -> Position {
        let radians = Double.pi / 180
        // Days since J2000.0 (JD 2451545.0), with the fractional day.
        let julianDay = date.timeIntervalSince1970 / 86400 + 2440587.5
        let n = julianDay - 2451545.0
        // Ecliptic longitude of the sun.
        let meanLongitude = 280.460 + 0.9856474 * n
        let meanAnomaly = (357.528 + 0.9856003 * n) * radians
        let eclipticLongitude = (meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly)) * radians
        let obliquity = (23.439 - 0.0000004 * n) * radians
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        // Hour angle from Greenwich mean sidereal time.
        let siderealDegrees = 280.46061837 + 360.98564736629 * n + longitude
        let hourAngle = (siderealDegrees * radians - rightAscension)
        let phi = latitude * radians
        let sinElevation = sin(phi) * sin(declination) + cos(phi) * cos(declination) * cos(hourAngle)
        let elevation = asin(min(1, max(-1, sinElevation)))
        // Measured from south toward west, then turned to north-based.
        let fromSouth = atan2(sin(hourAngle), cos(hourAngle) * sin(phi) - tan(declination) * cos(phi))
        var azimuth = (fromSouth / radians + 180).truncatingRemainder(dividingBy: 360)
        if azimuth < 0 { azimuth += 360 }
        return Position(elevation: elevation / radians, azimuth: azimuth)
    }
}
