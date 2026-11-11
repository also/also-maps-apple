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
    /// C₁: the raised content centre at full tilt. In a host whose view
    /// centre follows the tilt, the view centre rises from C₀ to C₁.
    var placementDown: SIMD3<Double>
    /// Half-width of the shown region and the gesture slab.
    var contentHalfWidth: Double
    /// The tilt at full weight, radians about the room's right axis through
    /// E: 0 level, π/2 the ground below straight ahead.
    var fullTilt = Double.pi / 2
    /// Whether the view centre (gesture slab, area of interest, ground
    /// sample) rises with the tilt from C₀ toward C₁, as the volume needs to
    /// keep it in the box. Otherwise it's the ground beneath C₀ while level,
    /// carried by the tilt.
    var viewCentreFollowsTilt = false

    /// C(w): the content centre at tilt weight `w`.
    func contentCentre(tiltWeight w: Double) -> SIMD3<Double> {
        placementLevel + (placementDown - placementLevel) * w
    }

    /// The tilt that points the ground below the eye at C₁: 90° less the
    /// angle E→C₁ dips below the horizontal.
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
