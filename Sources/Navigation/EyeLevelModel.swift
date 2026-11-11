import Foundation
import simd

/// The room hosts' presentation (the volume and the immersive space): the
/// camera is at the design eye point at every altitude, and the map is level
/// unless the tilt tips it.
///
/// - Untilted, the ground beneath the camera sits on the base plane below
///   the design eye point, and the camera's heading faces away from the
///   viewer. The scale makes the camera's height above that ground the
///   eye's height above the base plane (or is fixed, as at human scale).
///   The camera's pitch plays no part.
/// - The tilt turns the world about the room's right axis through the eye,
///   so the camera stays on the eye and the ground below comes up toward
///   straight ahead, like looking down at a globe. Its weight is the
///   interaction mode's choice; drone mode's assist follows the camera's
///   height above the ellipsoid (`tiltWeight`). Each host says how far full
///   weight tilts (`RoomGeometry.fullTilt`).
///
/// The returned framing's georeference point is the view centre: what
/// gestures grab and what the area of interest and ground sample centre on.
/// It's the ground along the line of sight `RoomGeometry.sightLine`: C₀
/// while level, the ground below the navigation position at full tilt.
enum EyeLevelModel {
    /// Where the tilt assist starts, metres above the ellipsoid.
    static let tiltStartAltitude = 50_000.0

    /// 0 up to 50 km, 1 from 500 km, on a smoothstep in log(altitude).
    static func tiltWeight(altitude: Double) -> Double {
        let t = min(max(log(max(altitude, 1) / tiltStartAltitude) / log(10.0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Drone mode's tilt assist for `camera`: from its height above the
    /// ellipsoid, so the tilt depends on where the camera is and nothing
    /// else. (Terrain shifts the 50–500 km curve negligibly.)
    static func tiltWeight(for camera: CameraPose) -> Double {
        tiltWeight(altitude: camera.height)
    }

    /// The framing for `camera` over ground at `groundHeight` (metres above
    /// the ellipsoid), tilted by `tiltWeight` (0...1) of the host's full
    /// tilt. With `fixedScale` (1 is human scale) the scale stays put and the
    /// ground is wherever the camera's height puts it; otherwise the ground
    /// is on the base plane.
    static func framing(camera: CameraPose, room: RoomGeometry, groundHeight: Double,
                        tiltWeight w: Double, fixedScale: Double? = nil) -> AdaptiveModel.Framing {
        let eye = room.designEye
        let base = room.placementLevel
        let eyeHeight = max(eye.y - base.y, 0.01)
        let above = max(camera.height - groundHeight, AdaptiveModel.minimumRange)
        let scale = fixedScale ?? eyeHeight / above
        let rotation = levelRotation(camera)

        // The camera on the eye, level, then tilted about the eye.
        let level = Similarity(scale: scale, rotation: rotation,
                               translation: eye - scale * rotation.act(camera.position))
        let tilt = Similarity(scale: 1, rotation: simd_quatd(angle: w * room.fullTilt, axis: SIMD3(1, 0, 0)),
                              translation: .zero)
        let tilted = Similarity(translation: eye).after(tilt).after(Similarity(translation: -eye)).after(level)

        // The ground along the line of sight.
        let through = tilted.inverse.apply(eye + room.sightLine(tiltWeight: w))
        let georeferencePoint = ground(from: camera, toward: through, groundHeight: groundHeight)
        return AdaptiveModel.Framing(georeference: Georeference(tilted),
                                     georeferencePoint: georeferencePoint,
                                     placementPoint: tilted.apply(georeferencePoint),
                                     range: simd_distance(georeferencePoint, camera.position))
    }

    /// Where the ray from the camera through `point` (ECEF) meets the ground,
    /// or the ground beneath the camera if it doesn't.
    private static func ground(from camera: CameraPose, toward point: SIMD3<Double>,
                               groundHeight: Double) -> SIMD3<Double> {
        let ray = Ray(origin: camera.position, direction: point - camera.position)
        if case let .hit(hit, _) = Geodesy.intersect(ray: ray, surfaceHeight: groundHeight) { return hit }
        return Geodesy.ecef(camera.coordinate, height: groundHeight)
    }

    /// Level: the camera's local up is the room's up, its heading faces −z.
    private static func levelRotation(_ camera: CameraPose) -> simd_quatd {
        let frame = Geodesy.enu(latitude: camera.latitude, longitude: camera.longitude)
        let forward = frame.north * cos(camera.heading) + frame.east * sin(camera.heading)
        let right = frame.east * cos(camera.heading) - frame.north * sin(camera.heading)
        return simd_quatd(simd_double3x3(rows: [right, frame.up, -forward]))
    }

    /// A pose framing a place: `radius` metres of world across the content
    /// half-width, facing `heading`, with the centre (at `groundHeight`) as
    /// the view centre. Tilted as the assist would at that height when
    /// `tiltFollowsAltitude`. Its pitch looks at the centre; placement
    /// ignores it.
    static func framePlace(centre: GeoCoordinate, radius: Double, heading: Double,
                           room: RoomGeometry, groundHeight: Double = 0,
                           tiltFollowsAltitude: Bool = true) -> CameraPose {
        let scale = room.contentHalfWidth / max(radius, 1)
        let eye = room.designEye
        let base = room.placementLevel
        let height = groundHeight + max(eye.y - base.y, 0.01) / scale
        let weight = tiltFollowsAltitude ? tiltWeight(altitude: height) : 0
        let target = Geodesy.ecef(centre, height: groundHeight)
        // Start with C₀ this far ahead of the eye on the base plane, in world
        // metres.
        let ahead = simd_length(SIMD2(base.x - eye.x, base.z - eye.z)) / scale
        let start = GeoMath.destination(from: centre, bearing: heading + .pi, distance: ahead)
        return standpoint(viewing: target, from: start, iterations: 6, frame: {
            framing(camera: $0, room: room, groundHeight: groundHeight, tiltWeight: weight)
        }) { point in
            let distance = GeoMath.distance(from: point, to: centre)
            return CameraPose(latitude: point.latitude, longitude: point.longitude, height: height,
                              heading: NavigationOperations.wrapped(heading + GeoMath.bearingChange(from: centre, to: point)),
                              pitch: -atan2(height - groundHeight, max(distance, 1e-6)))
        }
    }

    /// `camera` moved to `height` (metres above the ellipsoid) with its view
    /// centre where it was: zoom in a room host. The heading relative to the
    /// view centre and the pitch are kept. The pose is a function of the view
    /// centre and the height alone, so zooming out and back in to the same
    /// height returns to the same view.
    static func pose(_ camera: CameraPose, at height: Double,
                     holdingViewCentre frame: (CameraPose) -> AdaptiveModel.Framing) -> CameraPose {
        let target = frame(camera).georeferencePoint
        let centre = Geodesy.geodetic(target).coordinate
        let heading = camera.heading - GeoMath.bearingChange(from: centre, to: camera.coordinate)
        // Start where the camera would be if the view centre's distance
        // scaled with the height above it.
        let centreHeight = Geodesy.geodetic(target).height
        let ratio = max(height - centreHeight, 1e-6) / max(camera.height - centreHeight, 1e-6)
        let start = GeoMath.destination(from: centre, bearing: GeoMath.bearing(from: centre, to: camera.coordinate),
                                        distance: GeoMath.distance(from: centre, to: camera.coordinate) * ratio)
        return standpoint(viewing: target, from: start, iterations: 20, frame: frame) { point in
            CameraPose(latitude: point.latitude, longitude: point.longitude, height: height,
                       heading: NavigationOperations.wrapped(heading + GeoMath.bearingChange(from: centre, to: point)),
                       pitch: camera.pitch)
        }
    }

    /// Nudges the standpoint, starting at `start`, until `target` (ECEF) is
    /// the view centre of `pose(standpoint)`.
    private static func standpoint(viewing target: SIMD3<Double>, from start: GeoCoordinate, iterations: Int,
                                   frame: (CameraPose) -> AdaptiveModel.Framing,
                                   pose: (GeoCoordinate) -> CameraPose) -> CameraPose {
        var standpoint = start
        for _ in 0..<iterations {
            let f = frame(pose(standpoint))
            // Moving the camera by Δ moves the map by −s·R·Δ.
            let miss = f.placementPoint - f.georeference.map(target)
            let shift = -f.georeference.rotation.inverse.act(miss) / f.georeference.scale
            if simd_length(shift) < 1e-9 * max(pose(standpoint).height, 1) { break }
            let frame = Geodesy.enu(latitude: standpoint.latitude, longitude: standpoint.longitude)
            standpoint = GeoMath.offset(standpoint, east: simd_dot(shift, frame.east),
                                        north: simd_dot(shift, frame.north))
        }
        return pose(standpoint)
    }
}
