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
    /// at most `rayHeight`) is what lands on the table or floor.
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

        // C rises from the level placement toward the looking-down one as
        // the camera pitches down.
        let levelPitch = room.levelPitch
        let w = min(max((levelPitch - pitch) / (levelPitch + .pi / 2), 0), 1)
        let c = room.placementLevel + (room.placementDown - room.placementLevel) * w

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
