import Foundation
import simd

/// A room host's fixed geometry in the map frame (y up, −z away from the
/// viewer), metres. The base plane is the horizontal plane the map's ground
/// is placed on: low in the volume, and in the immersive space the origin
/// plane (y = 0, the floor where the user stood when the space opened),
/// raised slightly.
struct RoomGeometry: Equatable {
    /// E: the viewer's eye. Assumed, or in the immersive space measured once
    /// when it opens; never the continuously tracked head.
    var designEye: SIMD3<Double>
    /// C₀: the content centre on the base plane, where the view centre sits
    /// while the map is level.
    var placementLevel: SIMD3<Double>
    /// Half-width of the shown region and the gesture slab.
    var contentHalfWidth: Double
    /// The tilt at full weight, radians about the room's right axis through
    /// E: 0 level, π/2 the ground below straight ahead.
    var fullTilt = Double.pi / 2

    /// The direction (unit) from E of the line of sight the view centre is
    /// on at tilt weight `w`. It faces straight ahead (−z) and dips as E→C₀
    /// does seen from the side while level, turning evenly with the tilt to
    /// where full tilt puts the ground below the navigation position (90°
    /// less `fullTilt`). So the view centre is C₀ while level and the ground
    /// below the navigation position at full tilt.
    func sightLine(tiltWeight w: Double) -> SIMD3<Double> {
        let level = atan2(designEye.y - placementLevel.y, max(designEye.z - placementLevel.z, 1e-9))
        let dip = level + (.pi / 2 - fullTilt - level) * w
        return SIMD3(0, -sin(dip), -cos(dip))
    }

    /// The tilt that points the ground below the eye at `point`: 90° less
    /// the angle E→point dips below the horizontal.
    static func tiltFacing(_ point: SIMD3<Double>, from eye: SIMD3<Double>) -> Double {
        let toPoint = point - eye
        let dip = atan2(-toPoint.y, simd_length(SIMD2(toPoint.x, toPoint.z)))
        return .pi / 2 - dip
    }
}

/// The physical container the map is shown in and its fixed geometry:
/// the volume, a layout on the immersive space's origin plane, or the macOS
/// window.
/// Independent of presentation style.
enum HostGeometry: Equatable {
    case room(RoomGeometry)
    /// The render camera is the camera.
    case window(fieldOfView: Double, aspect: Double)
}
