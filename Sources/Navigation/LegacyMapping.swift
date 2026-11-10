import Foundation
import simd

/// Today's focus-centric placement, extracted unchanged from MapModel
/// so it can be expressed as a georeference and compared with the camera
/// core. Temporary: to be removed.
enum LegacyMapping {
    /// What the focus-centric model stores.
    struct State: Equatable {
        var focus: GeoCoordinate
        /// Anchored ground height at the focus, metres above the ellipsoid.
        var focusHeight: Double
        /// View half-width, metres.
        var radius: Double
        /// Radians clockwise from north.
        var heading: Double
    }

    /// The presentation fields the placement uses.
    struct Presentation: Equatable {
        var isVolume: Bool
        var magnification: Double
        var groundPosition: SIMD3<Double>
        var viewerPosition: SIMD3<Double>
    }

    /// Half the volume's width, metres.
    static let volumeHalfWidth = 0.5
    /// How far a typical viewer stands from the volume; drives LOD.
    static let viewerDistanceInScene = 1.2

    /// Scene metres per world metre as the volume shows it. Streaming always
    /// uses this, so every presentation gets the same tiles at the same detail.
    static func streamingScale(radius: Double) -> Double { volumeHalfWidth / radius }

    /// Scene metres per world metre as displayed.
    static func sceneScale(_ state: State, _ presentation: Presentation) -> Double {
        streamingScale(radius: state.radius) * presentation.magnification
    }

    /// Full strength up to a 50 km half-width, fading smoothly, in log
    /// scale, to pivoting at the centre by 500 km.
    static func viewerPivotWeight(radius: Double) -> Double {
        let t = log(radius / 50_000) / log(500_000 / 50_000.0)
        let clamped = min(max(t, 0), 1)
        return 1 - clamped * clamped * (3 - 2 * clamped)
    }

    /// 0 up close, 1 far away: how far the map tilts to face the viewer.
    static func farTilt(radius: Double) -> Double { 1 - viewerPivotWeight(radius: radius) }

    /// The map's centre, rising with the tilt from the base plane toward a little
    /// below eye level (the volume's middle in the volume).
    static func tiltedGroundPosition(_ state: State, _ presentation: Presentation) -> SIMD3<Double> {
        let ground = presentation.groundPosition
        let target = presentation.isVolume ? 0 : presentation.viewerPosition.y - 0.3
        return ground + SIMD3(0, (target - ground.y) * farTilt(radius: state.radius), 0)
    }

    /// Tilt that points the map's up from its raised centre at the viewer's
    /// eyes, scaled by how far away you are.
    static func tiltAngle(_ state: State, _ presentation: Presentation) -> Double {
        let toEye = presentation.viewerPosition - tiltedGroundPosition(state, presentation)
        return atan2(toEye.z, toEye.y) * farTilt(radius: state.radius)
    }

    /// The tilt, then the heading, about the map frame's axes.
    static func rotation(_ state: State, _ presentation: Presentation) -> simd_quatd {
        simd_quatd(angle: tiltAngle(state, presentation), axis: SIMD3(1, 0, 0))
            * simd_quatd(angle: state.heading, axis: SIMD3(0, 1, 0))
    }

    /// The focus's anchor frame → map frame.
    static func placement(_ state: State, _ presentation: Presentation) -> Similarity {
        Similarity(scale: sceneScale(state, presentation),
                   rotation: rotation(state, presentation),
                   translation: tiltedGroundPosition(state, presentation))
    }

    static func anchor(_ state: State) -> StreamingAnchor {
        StreamingAnchor(coordinate: state.focus, height: state.focusHeight)
    }

    /// World → map frame, with the old held-tile scene pose (if any) applied after.
    static func georeference(_ state: State, _ presentation: Presentation,
                             heldPose: Similarity = .identity) -> Georeference {
        Georeference(heldPose.after(placement(state, presentation)).after(anchor(state).ecefFromAnchor.inverse))
    }

    /// The LOD camera, region and anchor today's streaming uses.
    static func streamingInputs(_ state: State, _ presentation: Presentation,
                                immersiveRegion: Double) -> StreamingInputs {
        StreamingInputs(
            anchor: anchor(state),
            // The LOD camera looks down more steeply as the map turns to
            // face you: 45° when flat, straight down when fully tilted.
            lod: .orbit(heading: state.heading,
                        elevation: .pi / 4 + .pi / 4 * farTilt(radius: state.radius),
                        distance: viewerDistanceInScene / streamingScale(radius: state.radius)),
            regionHeading: state.heading,
            // Only the immersive modes stream past the volume-sized square; the
            // volume would clip the extra away anyway.
            streamingRadius: presentation.isVolume ? state.radius : state.radius * immersiveRegion)
    }
}
