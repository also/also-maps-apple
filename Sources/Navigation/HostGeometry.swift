import Foundation
import simd

/// A room host's fixed geometry in the map frame (y up, −z away from the
/// viewer), meters. The base plane is the horizontal plane the map's ground
/// is placed on: low in the volume, and in the immersive space the origin
/// plane (y = 0, the floor where the user stood when the space opened),
/// raised slightly.
struct RoomGeometry: Equatable {
    /// E: the viewer's eye. Assumed, or in the immersive space measured once
    /// when it opens; never the continuously tracked head.
    var designEye: SIMD3<Double>
    /// C₀: the content center on the base plane. Unless `restingDip` is set,
    /// it's where the view center sits while the map is level.
    var placementLevel: SIMD3<Double>
    /// Half-width of the shown region.
    var contentHalfWidth: Double
    /// The tilt at full weight, radians about the room's right axis (through
    /// `tiltPivot`): 0 level, π/2 the ground below straight ahead.
    var fullTilt = Double.pi / 2
    /// How far below level the view center's line of sight dips while the
    /// map is level, radians. nil: as E→C₀ does, which suits a host whose
    /// content is in a fixed place, like the volume's box. A chosen angle
    /// suits a host with the viewer's head in the map: the view center is
    /// then the same distance ahead in the world for any eye height.
    var restingDip: Double?

    /// The dip of the line of sight while level: `restingDip`, or E→C₀'s
    /// seen from the side.
    var levelDip: Double {
        restingDip ?? atan2(designEye.y - placementLevel.y, max(designEye.z - placementLevel.z, 1e-9))
    }

    /// How far from E the line of sight meets the base plane while level.
    var levelReach: Double {
        guard let restingDip else { return simd_distance(placementLevel, designEye) }
        return max(designEye.y - placementLevel.y, 0.01) / max(sin(restingDip), 1e-9)
    }

    /// Where the view center sits on the base plane while the map is level
    /// and the ground flat: C₀, or with a `restingDip` the point ahead of E
    /// where that line meets the base plane.
    var levelViewCenter: SIMD3<Double> {
        restingDip == nil ? placementLevel : designEye + sightLine(tiltWeight: 0) * levelReach
    }

    /// The direction (unit) from E of the line of sight the view center is
    /// on at tilt weight `w`. It faces straight ahead (−z) and dips by
    /// `levelDip` while level, turning evenly with the tilt to where full
    /// tilt puts the ground below the navigation position (90° less
    /// `fullTilt`). So the view center is `levelViewCenter` while level and
    /// the ground below the navigation position at full tilt. (High up, the
    /// framing keeps the line clear of the horizon: see
    /// `EyeLevelModel.horizonMargin`.)
    func sightLine(tiltWeight w: Double) -> SIMD3<Double> {
        let level = levelDip
        let dip = level + (.pi / 2 - fullTilt - level) * w
        return SIMD3(0, -sin(dip), -cos(dip))
    }

    /// The point the tilt turns the world about, with the ground below the
    /// navigation position on the base plane while level. Full tilt turns
    /// that ground to face E along the full-tilt line of sight, as far from
    /// E as the level view center is. So a point grabbed at the view center can stay about as
    /// far away whether the map is tilted or level. (About E itself, the
    /// ground below would stay E's height away at every tilt.)
    var tiltPivot: SIMD3<Double> {
        tiltPivot(groundBelow: max(designEye.y - placementLevel.y, 0.01))
    }

    /// `tiltPivot` for a level ground `groundBelow` meters below E: the
    /// same shape, scaled about E. Whatever the scale, the tilt then keeps
    /// what's seen from E the same, so changing only the scale (as human
    /// scale does) leaves the picture from E unchanged.
    func tiltPivot(groundBelow: Double) -> SIMD3<Double> {
        let eyeHeight = max(designEye.y - placementLevel.y, 0.01)
        let below = designEye - SIMD3(0, groundBelow, 0)
        let turn = simd_quatd(angle: fullTilt, axis: SIMD3(1, 0, 0))
        let reach = levelReach * groundBelow / eyeHeight
        let target = designEye + turn.act(SIMD3(0, -1, 0)) * reach
        // pivot + turn(below − pivot) = target, in the y–z plane.
        let c = cos(fullTilt), s = sin(fullTilt)
        let rhs = target - turn.act(below)
        let m = simd_double2x2(rows: [SIMD2(1 - c, s), SIMD2(-s, 1 - c)])
        guard abs(m.determinant) > 1e-9 else { return designEye }
        let yz = m.inverse * SIMD2(rhs.y, rhs.z)
        return SIMD3(designEye.x, yz.x, yz.y)
    }

    /// The turn of the view center's line of sight (`sightLine`) between
    /// two tilts, given as rotations about the room's right axis.
    func sightTurn(from start: simd_quatd, to end: simd_quatd) -> simd_quatd {
        func weight(_ tilt: simd_quatd) -> Double {
            guard abs(fullTilt) > 1e-9 else { return 0 }
            return 2 * atan2(tilt.imag.x, tilt.real) / fullTilt
        }
        return simd_quatd(from: sightLine(tiltWeight: weight(start)), to: sightLine(tiltWeight: weight(end)))
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
