import Foundation
import simd

/// What's left of the adaptive model presentation style, shared by the room
/// hosts' placement (`EyeLevelModel`): the framing it produces, the LOD
/// camera, anchored manipulation, and the horizon pitch limit (docs/camera-core.md
/// §6, for modes that need a view ray to meet the ground).
enum AdaptiveModel {
    struct Framing: Equatable {
        var georeference: Georeference
        /// G, the view centre, ECEF.
        var georeferencePoint: SIMD3<Double>
        /// Where G is placed, map frame.
        var placementPoint: SIMD3<Double>
        /// |G − X|, metres.
        var range: Double

        /// Half-width of the shown region, world metres.
        func shownRadius(_ room: RoomGeometry) -> Double {
            room.contentHalfWidth / georeference.scale
        }
    }

    /// Shortest height above the ground a framing uses, so scale stays finite.
    static let minimumRange = 1.0

    /// θ_lim: the shallowest pitch a framing allows, keeping the view ray
    /// `margin` radians below the horizon seen from `cameraHeight` over a
    /// surface at `rayHeight` (both above the ellipsoid, at `latitude`).
    static func pitchLimit(cameraHeight: Double, rayHeight: Double, latitude: Double,
                           margin: Double = 8 * .pi / 180) -> Double {
        guard cameraHeight.isFinite, rayHeight.isFinite, cameraHeight > rayHeight else { return -margin }
        let sinPhi = sin(latitude * .pi / 180)
        let primeVertical = Geodesy.semiMajorAxis
            / (1 - Geodesy.eccentricitySquared * sinPhi * sinPhi).squareRoot()
        let ratio = (primeVertical + rayHeight) / (primeVertical + cameraHeight)
        let dip = acos(min(max(ratio, 0), 1))
        return -(dip + margin)
    }
}

// MARK: LOD and anchored manipulation

extension AdaptiveModel {
    /// The LOD camera for a viewer at `eye` (map frame) looking at the
    /// framing's placement point, expressed in `anchor`'s frame.
    static func lodCamera(framing: Framing, eye: SIMD3<Double>, anchor: StreamingAnchor,
                          fieldOfView: Double = .pi / 3) -> LODCamera {
        let toWorld = framing.georeference.similarity.inverse
        let toAnchor = anchor.ecefFromAnchor.inverse
        let look = simd_normalize(framing.placementPoint - eye)
        let right = simd_normalize(simd_cross(look, SIMD3(0, 1, 0)))
        let up = simd_cross(right, look)
        let rotation = toAnchor.rotation * toWorld.rotation
        return LODCamera(position: toAnchor.apply(toWorld.apply(eye)),
                         direction: simd_normalize(rotation.act(look)),
                         up: simd_normalize(rotation.act(up)),
                         fieldOfView: fieldOfView)
    }

    /// What an anchored manipulation asks for: keep world point `grab`
    /// under map-frame point `target` at `scale`, with the view heading
    /// `heading`.
    struct AnchorTarget {
        var grab: SIMD3<Double>
        var target: SIMD3<Double>
        var scale: Double
        /// View heading at `headingOrigin`.
        var heading: Double
        var headingOrigin: GeoCoordinate

        func heading(at coordinate: GeoCoordinate) -> Double {
            heading + GeoMath.bearingChange(from: headingOrigin, to: coordinate)
        }
    }

    /// The camera pose whose framing (from `frame`) puts `anchor.grab` at
    /// `anchor.target` with the requested scale and heading, starting from
    /// `guess` (the previous solution). The heading is carried along the
    /// globe from `anchor.headingOrigin` as the camera moves, as travel does;
    /// the pitch is left as it is. The scale is taken to be inversely
    /// proportional to the camera's height above `scaleSurface`. The error
    /// counts both the grab point's distance from the target and the scale's,
    /// as the distance it would move the eye-to-placement span. A bounded
    /// iteration corrects scale and position together; it returns the best
    /// pose found and its remaining error in map-frame metres. See
    /// docs/camera-core.md §11.
    static func solve(_ anchor: AnchorTarget, from guess: CameraPose, room: RoomGeometry,
                      scaleSurface: Double, context: NavigationContext,
                      iterations: Int = 8, tolerance: Double = 1e-4,
                      frame: (CameraPose) -> Framing) -> (pose: CameraPose, error: Double) {
        var pose = guess
        var best = (pose: guess, error: Double.infinity)
        for _ in 0..<iterations {
            pose.heading = anchor.heading(at: pose.coordinate)
            let framing = frame(pose)
            let error = anchor.target - framing.georeference.map(anchor.grab)
            let scaleRatio = framing.georeference.scale / anchor.scale
            let span = simd_distance(framing.placementPoint, room.designEye)
            let errorLength = max(simd_length(error), abs(scaleRatio - 1) * span)
            if errorLength < best.error { best = (pose, errorLength) }
            if errorLength < tolerance { break }

            // Scale: inversely proportional to the height above the scale
            // surface, so scale that height.
            let above = max(pose.height - scaleSurface, 0.1)
            pose.height = context.clampHeight(scaleSurface + above * scaleRatio)

            // Position: shifting the camera by Δ moves the grab point by
            // −s·q·Δ in the map frame.
            let shift = -framing.georeference.rotation.inverse.act(error) / framing.georeference.scale
            let frame = Geodesy.enu(latitude: pose.latitude, longitude: pose.longitude)
            let east = simd_dot(shift, frame.east), north = simd_dot(shift, frame.north)
            let moved = GeoMath.offset(pose.coordinate, east: east, north: north)
            pose.latitude = moved.latitude
            pose.longitude = moved.longitude
        }
        return best
    }
}
