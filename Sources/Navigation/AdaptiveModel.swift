import Foundation
import simd

/// What's left of the adaptive model presentation style, shared by the room
/// hosts' placement (`EyeLevelModel`): the framing it produces, the LOD
/// camera, anchored manipulation, and the horizon pitch limit (for modes
/// that need a view ray to meet the ground).
enum AdaptiveModel {
    struct Framing: Equatable {
        var georeference: Georeference
        /// G, the view center, ECEF.
        var georeferencePoint: SIMD3<Double>
        /// Where G is placed, map frame.
        var placementPoint: SIMD3<Double>
        /// |G − X|, meters.
        var range: Double

        /// Half-width of the shown region, world meters.
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

// MARK: LOD and pinch manipulation

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

    /// A pinch on the map: the grabbed point and what the hands have done
    /// since the pinch began.
    struct Grab {
        /// The grabbed world point, ECEF.
        var point: SIMD3<Double>
        /// Where it was when the pinch began, map frame.
        var start: SIMD3<Double>
        /// The georeference's rotation (ECEF → map frame) then.
        var startRotation: simd_quatd
        /// The hand's movement since, map frame.
        var translation = SIMD3<Double>.zero
        /// Radians about the ground's up at the grabbed point; the world
        /// turns counterclockwise seen from above.
        var twist = 0.0
    }

    /// The camera at `height` that shows `grab` as the hands ask, found
    /// directly rather than by search.
    ///
    /// At a given height the world shown is a globe whose center and size
    /// are fixed in the room; only its orientation depends on where the
    /// camera is and which way it faces. So the pinch is a rotation of that
    /// globe about its center:
    /// - The grabbed point keeps its direction from the center as seen from
    ///   where the pinch began, which zooms about it.
    /// - The hand's movement rolls it along the surface by the same
    ///   distance: on a nearly flat map that's moving it with the hand; on a
    ///   globe it keeps turning past the edge as long as the hand moves.
    /// - The twist turns the globe about the grabbed point's up.
    /// The camera is then whichever pose gives that orientation, so there's
    /// always an answer, including where the tilt changes with height.
    static func pose(for grab: Grab, height: Double, from camera: CameraPose,
                     iterations: Int = 3, frame: (CameraPose) -> Framing) -> CameraPose {
        var pose = camera
        pose.height = height
        let startDirection = simd_normalize(grab.startRotation.act(grab.point))
        for _ in 0..<iterations {
            let framing = frame(pose)
            let georeference = framing.georeference
            // The tilt depends on the height alone: what's left of the
            // rotation once the camera's level rotation is taken out.
            let tilt = georeference.rotation * EyeLevelModel.levelRotation(pose).inverse
            let center = georeference.map(.zero)
            let radius = georeference.scale * simd_length(grab.point)
            let held = simd_normalize(grab.start - center)
            let roll = roll(held, by: grab.translation, radius: radius)
            let direction = roll.act(held)
            // Built as a turn about a fixed axis rather than the shortest
            // turn from start to finish, which has no fixed axis once the
            // point has rolled to the far side.
            let rotation = simd_quatd(angle: grab.twist, axis: direction)
                * roll
                * simd_quatd(from: startDirection, to: held)
                * grab.startRotation
            pose = Self.camera(level: tilt.inverse * rotation, height: height, pitch: camera.pitch)
        }
        return pose
    }

    /// The turn of a globe of `radius` that rolls the point in `direction`
    /// (unit, from its center) toward `translation`, as far along the
    /// surface as the translation's part along it.
    static func roll(_ direction: SIMD3<Double>, by translation: SIMD3<Double>,
                     radius: Double) -> simd_quatd {
        let along = translation - direction * simd_dot(translation, direction)
        let distance = simd_length(along)
        guard distance > 0, radius > 0 else { return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }
        return simd_quatd(angle: distance / radius, axis: simd_normalize(simd_cross(direction, along)))
    }

    /// The camera at `height` whose level rotation (ECEF → room, before the
    /// tilt) is `level`: its up gives the place, its forward the heading.
    private static func camera(level: simd_quatd, height: Double, pitch: Double) -> CameraPose {
        let toWorld = level.inverse
        let up = toWorld.act(SIMD3(0, 1, 0))
        let forward = toWorld.act(SIMD3(0, 0, -1))
        let latitude = atan2(up.z, (up.x * up.x + up.y * up.y).squareRoot()) * 180 / .pi
        let longitude = atan2(up.y, up.x) * 180 / .pi
        let frame = Geodesy.enu(latitude: latitude, longitude: longitude)
        let heading = atan2(simd_dot(forward, frame.east), simd_dot(forward, frame.north))
        return CameraPose(latitude: latitude, longitude: longitude, height: height,
                          heading: NavigationOperations.wrapped(heading), pitch: pitch)
    }
}
