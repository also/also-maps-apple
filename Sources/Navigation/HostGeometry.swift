import Foundation
import simd

/// A room host's fixed geometry in the map frame (y up, −z away from the
/// viewer), metres.
struct RoomGeometry: Equatable {
    /// E: the assumed viewer position, not the tracked head.
    var designEye: SIMD3<Double>
    /// C₀: where the georeference point goes when the map is level.
    var placementLevel: SIMD3<Double>
    /// C₁: where it goes looking straight down.
    var placementDown: SIMD3<Double>
    /// Half-width of the shown region and the gesture slab.
    var contentHalfWidth: Double

    /// θ₀: the pitch from E to C₀, radians (negative: looking down).
    var levelPitch: Double {
        let toLevel = simd_normalize(placementLevel - designEye)
        return asin(min(max(toLevel.y, -1), 1))
    }
}

/// The physical container the map is shown in and its fixed geometry:
/// the volume, a floor layout in the immersive space, or the macOS window.
/// Independent of presentation style.
enum HostGeometry: Equatable {
    case room(RoomGeometry)
    /// The render camera is the camera.
    case window(fieldOfView: Double, aspect: Double)
}
