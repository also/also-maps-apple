import Foundation
import simd

/// A half-line from `origin` along `direction`, ECEF metres.
struct Ray: Equatable {
    var origin: SIMD3<Double>
    var direction: SIMD3<Double>
}

/// The result of a surface query. A miss is a normal answer (looking level
/// or into the sky); `invalidRay` means the query itself was malformed.
enum SurfaceHit: Equatable {
    /// The first point along the ray at the requested height; `t` is the
    /// distance along the (unit) direction, ≥ 0.
    case hit(point: SIMD3<Double>, t: Double)
    case miss
    case invalidRay
}

/// WGS84 geometry in double precision: geodetic ↔ ECEF, local frames and the
/// surface query. Matches cesium-native's Ellipsoid::WGS84 and
/// eastNorthUpToFixedFrame, so frames built here line up with the bridge's.
enum Geodesy {
    static let semiMajorAxis = 6_378_137.0
    static let flattening = 1 / 298.257223563
    static let semiMinorAxis = semiMajorAxis * (1 - flattening)
    /// First eccentricity squared.
    static let eccentricitySquared = flattening * (2 - flattening)

    /// A point at `height` metres above the ellipsoid.
    static func ecef(latitude: Double, longitude: Double, height: Double) -> SIMD3<Double> {
        let phi = latitude * .pi / 180, lambda = longitude * .pi / 180
        let sinPhi = sin(phi)
        let n = semiMajorAxis / (1 - eccentricitySquared * sinPhi * sinPhi).squareRoot()
        return SIMD3((n + height) * cos(phi) * cos(lambda),
                     (n + height) * cos(phi) * sin(lambda),
                     (n * (1 - eccentricitySquared) + height) * sinPhi)
    }

    static func ecef(_ coordinate: GeoCoordinate, height: Double) -> SIMD3<Double> {
        ecef(latitude: coordinate.latitude, longitude: coordinate.longitude, height: height)
    }

    /// Latitude and longitude in degrees, height in metres above the
    /// ellipsoid. Fixed-point iteration on latitude; converges to well under
    /// a millimetre in a few steps for any point outside the Earth's core.
    static func geodetic(_ p: SIMD3<Double>) -> (coordinate: GeoCoordinate, height: Double) {
        let horizontal = (p.x * p.x + p.y * p.y).squareRoot()
        let lambda = atan2(p.y, p.x)
        guard horizontal > 1e-9 else {
            let polar = p.z >= 0 ? 90.0 : -90.0
            return (GeoCoordinate(latitude: polar, longitude: 0), abs(p.z) - semiMinorAxis)
        }
        var phi = atan2(p.z, horizontal * (1 - eccentricitySquared))
        var height = 0.0
        for _ in 0..<8 {
            let sinPhi = sin(phi)
            let w = (1 - eccentricitySquared * sinPhi * sinPhi).squareRoot()
            let n = semiMajorAxis / w
            // Exact for this latitude, and well-conditioned at any latitude.
            height = horizontal * cos(phi) + p.z * sinPhi - semiMajorAxis * w
            let next = atan2(p.z, horizontal * (1 - eccentricitySquared * n / (n + height)))
            if abs(next - phi) < 1e-14 { phi = next; break }
            phi = next
        }
        return (GeoCoordinate(latitude: phi * 180 / .pi, longitude: lambda * 180 / .pi), height)
    }

    /// Unit east, north and up at a latitude and longitude, ECEF. Up is the
    /// ellipsoid normal.
    static func enu(latitude: Double, longitude: Double) -> (east: SIMD3<Double>, north: SIMD3<Double>, up: SIMD3<Double>) {
        let phi = latitude * .pi / 180, lambda = longitude * .pi / 180
        let east = SIMD3(-sin(lambda), cos(lambda), 0)
        let north = SIMD3(-sin(phi) * cos(lambda), -sin(phi) * sin(lambda), cos(phi))
        let up = SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
        return (east, north, up)
    }

    /// Rotation from an anchor frame (RealityKit axes: x east, y up, z
    /// south) to ECEF axes. Its columns are east, up and south.
    static func anchorFrameRotation(latitude: Double, longitude: Double) -> simd_double3x3 {
        let frame = enu(latitude: latitude, longitude: longitude)
        return simd_double3x3(columns: (frame.east, frame.up, -frame.north))
    }

    // MARK: Surface query

    /// Iterations allowed when refining a quadric hit to constant geodetic
    /// height, and the residual accepted.
    private static let refinementIterations = 4
    private static let refinementTolerance = 1e-4
    /// Below this |up · direction| the height changes too slowly along the
    /// ray to refine safely (grazing); the quadric hit is returned as is.
    private static let refinementMinimumSlope = 1e-3

    /// The first point along `ray` at `surfaceHeight` metres above the
    /// ellipsoid, or a miss.
    ///
    /// The surface is approximated by the ellipsoid with semi-axes
    /// (a + h, a + h, b + h), a closed-form quadric. It departs from constant
    /// geodetic height by at most about |h|·e²/2 (≈ 30 m at 9 km). A hit is
    /// then refined toward the true height by a bounded Newton iteration on
    /// the height along the ray, only while that is well-conditioned, and
    /// always staying on the forward ray. A camera inside the surface gets
    /// the forward exit point, so a valid ray always has an answer there.
    static func intersect(ray: Ray, surfaceHeight h: Double) -> SurfaceHit {
        let length = simd_length(ray.direction)
        guard length > 0, length.isFinite, h.isFinite,
              ray.origin.x.isFinite, ray.origin.y.isFinite, ray.origin.z.isFinite
        else { return .invalidRay }
        let direction = ray.direction / length
        let a = semiMajorAxis + h, b = semiMinorAxis + h
        guard a > 0, b > 0 else { return .invalidRay }

        // In coordinates where the quadric is the unit sphere.
        let scale = SIMD3(1 / a, 1 / a, 1 / b)
        let o = ray.origin * scale, d = direction * scale
        let qa = simd_dot(d, d)
        let qb = 2 * simd_dot(o, d)
        let qc = simd_dot(o, o) - 1
        let discriminant = qb * qb - 4 * qa * qc
        guard discriminant >= 0 else { return .miss }
        let root = discriminant.squareRoot()
        // Numerically stable pair of roots.
        let q = -0.5 * (qb + (qb >= 0 ? root : -root))
        var roots = [q / qa]
        if q != 0 { roots.append(qc / q) }
        let t: Double
        if qc < 0 {
            // Inside: the one forward root.
            guard let exit = roots.filter({ $0 >= 0 }).max() else { return .miss }
            t = exit
        } else {
            guard let entry = roots.filter({ $0 >= 0 }).min() else { return .miss }
            t = entry
        }
        let refined = refine(origin: ray.origin, direction: direction, t: t, height: h)
        return .hit(point: ray.origin + direction * refined, t: refined)
    }

    private static func refine(origin: SIMD3<Double>, direction: SIMD3<Double>, t start: Double, height: Double) -> Double {
        var t = start
        for _ in 0..<refinementIterations {
            let point = origin + direction * t
            let (coordinate, pointHeight) = geodetic(point)
            let residual = pointHeight - height
            if abs(residual) < refinementTolerance { break }
            let slope = simd_dot(enu(latitude: coordinate.latitude, longitude: coordinate.longitude).up, direction)
            guard abs(slope) > refinementMinimumSlope else { break }
            let next = t - residual / slope
            guard next >= 0, next.isFinite else { break }
            t = next
        }
        return t
    }
}
