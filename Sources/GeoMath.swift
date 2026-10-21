import Foundation

/// A point on the globe, degrees.
struct GeoCoordinate: Equatable {
    var latitude: Double
    var longitude: Double
}

/// Spherical-Earth navigation for moving the focus. A sphere is plenty for
/// steering (errors are a fraction of a percent); everything drawn is placed
/// with cesium-native's WGS84 ellipsoid.
enum GeoMath {
    static let earthRadius = 6_371_000.0

    /// The point `distance` metres from `start` along a great circle leaving
    /// at `bearing` radians clockwise from north.
    static func destination(from start: GeoCoordinate, bearing: Double, distance: Double) -> GeoCoordinate {
        guard distance != 0 else { return start }
        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180
        let angular = distance / earthRadius
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))
        return GeoCoordinate(latitude: lat2 * 180 / .pi,
                             longitude: normalizedLongitude(lon2 * 180 / .pi))
    }

    /// The point offset from `start` by local east/north metres, i.e. leaving
    /// in that direction for that distance.
    static func offset(_ start: GeoCoordinate, east: Double, north: Double) -> GeoCoordinate {
        destination(from: start, bearing: atan2(east, north), distance: (east * east + north * north).squareRoot())
    }

    /// Initial great-circle bearing from `a` to `b`, radians clockwise from north.
    static func bearing(from a: GeoCoordinate, to b: GeoCoordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        return atan2(sin(dLon) * cos(lat2),
                     cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon))
    }

    static func normalizedLongitude(_ degrees: Double) -> Double {
        var value = (degrees + 180).truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value - 180
    }
}
