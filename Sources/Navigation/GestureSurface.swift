import Foundation
import simd

/// The shape gaze lands on to start a gesture: a cap of the ellipsoid raised
/// to the placement ground, so where gaze hits it is where it meets the
/// ground as shown (#61). A flat slab drifts off the curved ground away from
/// its center and stands up in front of the viewer when the map tilts.
///
/// The cap is a convex hull of points on that surface. Gaze from above hits
/// its curved top; a ray past its rim misses it. It's built in its center's
/// anchor frame (x east, y up, z south) in units of `unit` meters, so it
/// keeps Float precision at any size, and is only rebuilt when the view has
/// moved enough to need it (`needsRebuild`).
struct GestureSurface: Equatable {
    var center: GeoCoordinate
    /// Meters above the ellipsoid.
    var height: Double
    /// Radians of arc from the center to the rim.
    var angularRadius: Double

    static let rings = 8
    static let bearings = 24
    /// A hemisphere: no more of a globe can face the viewer.
    static let maximumAngularRadius = Double.pi / 2
    /// Built this much larger than asked, so it still covers after the view
    /// drifts a little.
    static let margin = 1.2

    /// Meters per local unit.
    var unit: Double { max(angularRadius * GeoMath.earthRadius, 1) }

    /// The cap a host needs: around `center`, reaching `reach` radians.
    static func desired(center: GeoCoordinate, height: Double, reach: Double) -> GestureSurface {
        GestureSurface(center: center, height: height,
                       angularRadius: min(max(reach, 1 / GeoMath.earthRadius), maximumAngularRadius))
    }

    /// Radians of arc from the point beneath a camera `cameraHeight` meters
    /// above the ellipsoid to its horizon on ground at `groundHeight`.
    static func horizonAngle(cameraHeight: Double, groundHeight: Double) -> Double {
        guard cameraHeight > groundHeight else { return 0 }
        let r = GeoMath.earthRadius
        return acos(min(max((r + groundHeight) / (r + cameraHeight), -1), 1))
    }

    /// The cap to build for `desired`: a little larger, so it still covers
    /// while the view drifts.
    static func built(for desired: GestureSurface) -> GestureSurface {
        var surface = desired
        surface.angularRadius = min(desired.angularRadius * margin, maximumAngularRadius)
        return surface
    }

    /// Whether this cap, built earlier, no longer serves `desired`: it
    /// doesn't cover it, it's so much larger that its facets are coarse, or
    /// its height is off. A change in height is otherwise taken up by
    /// placing the cap at the current height.
    func needsRebuild(for desired: GestureSurface) -> Bool {
        let drift = GeoMath.distance(from: center, to: desired.center) / GeoMath.earthRadius
        return drift > 0.1 * desired.angularRadius
            || desired.angularRadius > angularRadius
            || angularRadius > 1.6 * desired.angularRadius
            || abs(desired.height - height) > 0.001 * unit
    }

    /// Points on the cap, ECEF: the center, then rings out to the rim.
    func ecefPoints() -> [SIMD3<Double>] {
        var points = [Geodesy.ecef(center, height: height)]
        for ring in 1...Self.rings {
            let distance = angularRadius * Double(ring) / Double(Self.rings) * GeoMath.earthRadius
            for step in 0..<Self.bearings {
                let bearing = 2 * Double.pi * Double(step) / Double(Self.bearings)
                let point = GeoMath.destination(from: center, bearing: bearing, distance: distance)
                points.append(Geodesy.ecef(point, height: height))
            }
        }
        return points
    }

    /// The hull's points in the center's anchor frame, in units: the cap,
    /// plus one point just below its rim so a nearly flat cap still has
    /// volume.
    func localPoints() -> [SIMD3<Float>] {
        let origin = Geodesy.ecef(center, height: height)
        let toLocal = Geodesy.anchorFrameRotation(latitude: center.latitude, longitude: center.longitude).transpose
        var points = ecefPoints().map { toLocal * ($0 - origin) / unit }
        let rimDepth = points.map(\.y).min() ?? 0
        points.append(SIMD3(0, rimDepth - 0.02, 0))
        return points.map { SIMD3<Float>($0) }
    }

    /// `ecef` moved along the local vertical onto `height` meters above the
    /// ellipsoid: a hit on the hull, which lies a little inside the curved
    /// surface between its points, put on the surface.
    static func snap(_ ecef: SIMD3<Double>, toHeight height: Double) -> SIMD3<Double> {
        Geodesy.ecef(Geodesy.geodetic(ecef).coordinate, height: height)
    }
}
