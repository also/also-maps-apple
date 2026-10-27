import Foundation
import simd

/// The adaptive model presentation style for room hosts: the world is
/// scaled so a useful region fits in the room. The camera sits at the design
/// eye point, and the point its view ray meets on the ground (the
/// georeference point, G) sits at the placement point, C. See
/// docs/camera-core.md §4.1.
enum AdaptiveModel {
    struct Framing: Equatable {
        var georeference: Georeference
        /// G, ECEF.
        var georeferencePoint: SIMD3<Double>
        /// C, map frame.
        var placementPoint: SIMD3<Double>
        /// |G − X|, metres.
        var range: Double

        /// Half-width of the shown region, world metres.
        func shownRadius(_ room: RoomGeometry) -> Double {
            room.contentHalfWidth / georeference.scale
        }
    }

    /// Shortest range a framing uses, so scale stays finite.
    static let minimumRange = 1.0

    /// The framing for `camera`, or nil when its view ray misses the surface
    /// at `rayHeight`. The lowest ground of the footprint (`envelopeHeight`,
    /// at most `rayHeight`) is what lands on the base plane.
    static func framing(camera: CameraPose, room: RoomGeometry,
                        rayHeight: Double, envelopeHeight: Double) -> Framing? {
        let x = camera.position
        let basis = camera.basis
        guard case let .hit(g, _) = Geodesy.intersect(ray: Ray(origin: x, direction: basis.forward),
                                                       surfaceHeight: rayHeight)
        else { return nil }
        return framing(camera: x, forward: basis.forward, right: basis.right, georeferencePoint: g,
                       pitch: camera.pitch, room: room,
                       rayHeight: rayHeight, envelopeHeight: envelopeHeight)
    }

    /// The fallback when there's no valid framing to keep: look straight
    /// down at the ground beneath the camera, keeping its position and
    /// heading. Always finite.
    static func nadirFraming(camera: CameraPose, room: RoomGeometry,
                             rayHeight: Double, envelopeHeight: Double) -> Framing {
        let x = camera.position
        let up = Geodesy.enu(latitude: camera.latitude, longitude: camera.longitude).up
        let g = Geodesy.ecef(camera.coordinate, height: min(rayHeight, camera.height - minimumRange))
        return framing(camera: x, forward: -up, right: camera.basis.right, georeferencePoint: g,
                       pitch: -.pi / 2, room: room,
                       rayHeight: rayHeight, envelopeHeight: envelopeHeight)
    }

    private static func framing(camera x: SIMD3<Double>, forward f: SIMD3<Double>, right r: SIMD3<Double>,
                                georeferencePoint g: SIMD3<Double>, pitch: Double, room: RoomGeometry,
                                rayHeight: Double, envelopeHeight: Double) -> Framing {
        let range = max(simd_distance(g, x), minimumRange)

        let c = placementPoint(room, pitch: pitch)

        // Camera (right, up, back) → map-frame view basis (right, up, back).
        let e = room.designEye
        let u = simd_normalize(c - e)
        let rightMap = simd_normalize(simd_cross(u, SIMD3(0, 1, 0)))
        let upMap = simd_cross(rightMap, u)
        let up = simd_cross(r, f)
        let cameraBasis = simd_double3x3(columns: (r, up, -f))
        let mapBasis = simd_double3x3(columns: (rightMap, upMap, -u))
        let rotation = simd_quatd(mapBasis * cameraBasis.transpose)

        let scale = simd_distance(c, e) / range
        // Lower G to the footprint's envelope; that point goes on C.
        let (gCoordinate, _) = Geodesy.geodetic(g)
        let gUp = Geodesy.enu(latitude: gCoordinate.latitude, longitude: gCoordinate.longitude).up
        let lowered = g - gUp * max(rayHeight - envelopeHeight, 0)
        let translation = c - scale * rotation.act(lowered)
        return Framing(georeference: Georeference(scale: scale, rotation: rotation, translation: translation),
                       georeferencePoint: g, placementPoint: c, range: range)
    }

    /// C(θ): the placement point rises from the level one toward the
    /// looking-down one as the camera pitches down.
    static func placementPoint(_ room: RoomGeometry, pitch: Double) -> SIMD3<Double> {
        let levelPitch = room.levelPitch
        let w = min(max((levelPitch - pitch) / (levelPitch + .pi / 2), 0), 1)
        return room.placementLevel + (room.placementDown - room.placementLevel) * w
    }

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

// MARK: Pitch policy, places, LOD and anchored manipulation

extension AdaptiveModel {
    /// θ_target: the optional pitch-follows-altitude assist. The level map's
    /// pitch up to 50 km above ground, then straight down by 500 km on a
    /// smoothstep in log(altitude).
    static func pitchTarget(altitude: Double, levelPitch: Double) -> Double {
        let t = min(max(log(max(altitude, 1) / 50_000) / log(10.0), 0), 1)
        let w = t * t * (3 - 2 * t)
        return levelPitch + (-.pi / 2 - levelPitch) * w
    }

    /// A pose framing a place in `room`'s geometry: the centre (at
    /// `groundHeight`) lands on the level placement point, `radius` metres of
    /// world span the content half-width, facing `heading`.
    static func framePlace(centre: GeoCoordinate, radius: Double, heading: Double,
                           room: RoomGeometry, groundHeight: Double = 0) -> CameraPose {
        let scale = room.contentHalfWidth / max(radius, 1)
        let g = Geodesy.ecef(centre, height: groundHeight)
        // Pitch follows the altitude the framing gives; a few passes settle it.
        var pitch = room.levelPitch
        var pose = CameraPose(latitude: centre.latitude, longitude: centre.longitude, height: groundHeight,
                              heading: heading, pitch: pitch)
        for _ in 0..<3 {
            // The view direction as seen from the centre, backed off along.
            let atCentre = CameraPose(latitude: centre.latitude, longitude: centre.longitude,
                                      height: groundHeight, heading: heading, pitch: pitch)
            let forward = atCentre.basis.forward
            let range = simd_distance(placementPoint(room, pitch: pitch), room.designEye) / scale
            pose = CameraPose(position: g - forward * range, forward: forward, fallbackHeading: heading)
            pitch = pitchTarget(altitude: pose.height - groundHeight, levelPitch: room.levelPitch)
        }
        return pose
    }

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
    /// `heading`. `pitch` gives the pitch for a candidate altitude (the
    /// pitch policy, or the current pitch), before the horizon limit.
    struct AnchorTarget {
        var grab: SIMD3<Double>
        var target: SIMD3<Double>
        var scale: Double
        /// View heading at `headingOrigin`.
        var heading: Double
        var headingOrigin: GeoCoordinate
        var pitch: (Double) -> Double

        func heading(at coordinate: GeoCoordinate) -> Double {
            heading + GeoMath.bearingChange(from: headingOrigin, to: coordinate)
        }
    }

    /// The camera pose whose derived framing puts `anchor.grab` at
    /// `anchor.target` with the requested scale and heading, starting from
    /// `guess` (the previous solution). The heading is carried along the
    /// globe from `anchor.headingOrigin` as the camera moves, as travel does.
    /// The error counts both the grab point's distance from the target and
    /// the scale's, as the distance it would move the eye-to-placement span. A bounded iteration corrects scale
    /// and position together; it returns the best pose found and its
    /// remaining error in map-frame metres. See docs/camera-core.md §11.1.
    static func solve(_ anchor: AnchorTarget, from guess: CameraPose, room: RoomGeometry,
                      rayHeight: Double, envelopeHeight: Double, context: NavigationContext,
                      iterations: Int = 8, tolerance: Double = 1e-4) -> (pose: CameraPose, error: Double) {
        var pose = guess
        var best = (pose: guess, error: Double.infinity)
        for _ in 0..<iterations {
            // Orientation for this candidate: heading as asked, pitch from
            // the policy at its altitude, within the horizon limit.
            pose.heading = anchor.heading(at: pose.coordinate)
            let limit = pitchLimit(cameraHeight: pose.height, rayHeight: rayHeight, latitude: pose.latitude)
            pose.pitch = min(anchor.pitch(pose.height - context.cameraGround), limit)
            guard let framing = framing(camera: pose, room: room, rayHeight: rayHeight,
                                        envelopeHeight: envelopeHeight) else { break }
            let error = anchor.target - framing.georeference.map(anchor.grab)
            let scaleRatio = framing.georeference.scale / anchor.scale
            let span = simd_distance(framing.placementPoint, room.designEye)
            let errorLength = max(simd_length(error), abs(scaleRatio - 1) * span)
            if errorLength < best.error { best = (pose, errorLength) }
            if errorLength < tolerance { break }

            // Scale: range is proportional to height above the ray surface
            // at fixed pitch, so scale the height above it.
            let above = max(pose.height - rayHeight, 0.1)
            pose.height = context.clampHeight(rayHeight + above * scaleRatio)

            // Position: shifting the camera (and G with it) by Δ moves the
            // grab point by −s·q·Δ in the map frame.
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
