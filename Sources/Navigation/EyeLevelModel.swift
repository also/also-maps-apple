import Foundation
import simd

/// The immersive hosts' presentation: the camera is at the viewer's eye,
/// and the map is level unless the tilt tips it.
///
/// - Untilted, the ground beneath the camera sits on the base plane below
///   the design eye point, and the camera's heading faces away from the
///   viewer. The scale makes the camera's height above that ground the
///   eye's height above the base plane. The camera's pitch plays no part.
/// - The tilt follows altitude: none below 50 km above the ground, a quarter
///   turn by 500 km. As it grows, the camera's ground point slides out to
///   the map's centre point, C₀, which rises toward C₁, and the map turns
///   about the room's right axis there to face the viewer, like a globe.
///
/// The returned framing's georeference point is the ground at C₀: what
/// tilting and framing places are about.
enum EyeLevelModel {
    /// 0 up to 50 km above the ground, 1 from 500 km, on a smoothstep in
    /// log(altitude).
    static func tiltWeight(altitude: Double) -> Double {
        let t = min(max(log(max(altitude, 1) / 50_000) / log(10.0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The tilt for a weight, radians: 0 level, π/2 facing the viewer.
    static func tilt(weight: Double) -> Double { weight * .pi / 2 }

    /// The framing for `camera` over ground at `groundHeight` (metres above
    /// the ellipsoid), tilted by `tiltWeight` (0...1).
    static func framing(camera: CameraPose, room: RoomGeometry, groundHeight: Double,
                        tiltWeight w: Double) -> AdaptiveModel.Framing {
        let eye = room.designEye
        let base = room.placementLevel
        let eyeHeight = max(eye.y - base.y, 0.01)
        let above = max(camera.height - groundHeight, AdaptiveModel.minimumRange)
        let scale = eyeHeight / above

        // Level: the camera's local up is the room's up, its heading faces −z.
        let frame = Geodesy.enu(latitude: camera.latitude, longitude: camera.longitude)
        let forward = frame.north * cos(camera.heading) + frame.east * sin(camera.heading)
        let right = frame.east * cos(camera.heading) - frame.north * sin(camera.heading)
        let rotation = simd_quatd(simd_double3x3(rows: [right, frame.up, -forward]))

        // The ground beneath the camera goes below the eye, sliding out to C₀
        // as the map tilts.
        let ground = Geodesy.ecef(camera.coordinate, height: groundHeight)
        let footprint = SIMD3(eye.x + (base.x - eye.x) * w, base.y, eye.z + (base.z - eye.z) * w)
        let level = Similarity(scale: scale, rotation: rotation,
                               translation: footprint - scale * rotation.act(ground))

        // Tilt about the room's right axis through C₀, which rises toward C₁.
        let centre = base + (room.placementDown - base) * w
        let tilt = Similarity(scale: 1, rotation: simd_quatd(angle: tilt(weight: w), axis: SIMD3(1, 0, 0)),
                              translation: .zero)
        let tilted = Similarity(translation: centre)
            .after(tilt)
            .after(Similarity(translation: -base))
            .after(level)

        let georeferencePoint = level.inverse.apply(base)
        return AdaptiveModel.Framing(georeference: Georeference(tilted),
                                     georeferencePoint: georeferencePoint,
                                     placementPoint: centre,
                                     range: simd_distance(georeferencePoint, camera.position))
    }

    /// A pose framing a place, untilted: the centre (at `groundHeight`) on
    /// C₀, `radius` metres of world across the content half-width, facing
    /// `heading`. Its pitch looks at the centre; placement ignores it.
    static func framePlace(centre: GeoCoordinate, radius: Double, heading: Double,
                           room: RoomGeometry, groundHeight: Double = 0) -> CameraPose {
        let scale = room.contentHalfWidth / max(radius, 1)
        let eye = room.designEye
        let base = room.placementLevel
        let height = groundHeight + max(eye.y - base.y, 0.01) / scale
        // C₀ is this far ahead of the eye on the base plane, in world metres.
        let ahead = simd_length(SIMD2(base.x - eye.x, base.z - eye.z)) / scale
        var standpoint = GeoMath.destination(from: centre, bearing: heading + .pi, distance: ahead)
        let pitch = -atan2(height - groundHeight, max(ahead, 1e-6))
        let target = Geodesy.ecef(centre, height: groundHeight)
        // Facing the centre in the standpoint's own east-north frame.
        func pose(at point: GeoCoordinate) -> CameraPose {
            let frame = Geodesy.enu(latitude: point.latitude, longitude: point.longitude)
            let toCentre = target - Geodesy.ecef(point, height: groundHeight)
            let facing = ahead > 0 ? atan2(simd_dot(toCentre, frame.east), simd_dot(toCentre, frame.north)) : heading
            return CameraPose(latitude: point.latitude, longitude: point.longitude, height: height,
                              heading: facing, pitch: pitch)
        }
        // The destination is spherical; nudge the standpoint until the centre
        // lands on C₀ horizontally on the ellipsoid. (Below it, by the Earth's
        // curve, is right.)
        for _ in 0..<3 {
            let f = framing(camera: pose(at: standpoint), room: room, groundHeight: groundHeight, tiltWeight: 0)
            // Moving the camera by Δ moves the map by −scale·Δ, so move it by
            // −miss / scale: map x is the camera's right, map +z its back.
            let miss = base - f.georeference.map(target)
            let right = -miss.x / scale, back = -miss.z / scale
            let heading = pose(at: standpoint).heading
            standpoint = GeoMath.offset(standpoint,
                                        east: right * cos(heading) - back * sin(heading),
                                        north: -right * sin(heading) - back * cos(heading))
        }
        return pose(at: standpoint)
    }
}
