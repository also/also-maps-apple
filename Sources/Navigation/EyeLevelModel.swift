import Foundation
import simd

/// The room hosts' presentation (the volume and the immersive space): level,
/// the navigation position is at H, the design eye point
/// (`RoomGeometry.designEye`), and the tilt tips the map from there.
///
/// - Untilted, the ground beneath the navigation position sits on the base
///   plane below the design eye point, and its heading faces away from the
///   viewer. The scale makes its height above that ground the eye's height
///   above the base plane (or is fixed, as at human scale). The camera
///   pose's pitch plays no part.
/// - The tilt turns the world about the room's right axis through
///   `RoomGeometry.tiltPivot`, so the ground below comes up toward straight
///   ahead, like looking at a globe, and at full tilt is as far from the eye
///   as the view center is while level. The navigation position turns with
///   the world, off H. Its weight is the interaction mode's choice;
///   drone mode's assist follows the navigation position's height above the
///   ellipsoid (`tiltWeight`). Each host says how far full weight tilts
///   (`RoomGeometry.fullTilt`).
/// - The stored altitude (`CameraPose.height`) is H's height above the
///   ellipsoid. The navigation position is below the stored latitude and
///   longitude, low enough that H is at the stored altitude. Within the
///   tilt H drifts off that place horizontally, behind it by up to about 0.6× the navigation position's
///   height above the ground in the immersive space.
///
/// The returned framing's georeference point is the view center: what
/// gestures grab and what the area of interest and ground sample center on.
/// It's the ground along the line of sight `RoomGeometry.sightLine`: ahead
/// while level (C₀ in the volume, a fixed dip below level in the immersive
/// space), the ground below the navigation position at full tilt. High up
/// with little tilt, that line would pass over the globe, so it's kept
/// `horizonMargin` below the horizon.
enum EyeLevelModel {
    /// The closest the view center's line of sight comes to the horizon,
    /// radians. Where `RoomGeometry.sightLine` would come nearer (or pass
    /// over the globe), the line dips this far below the horizon instead, so
    /// climbing with no tilt the view center slides from ahead to below
    /// without a jump, and never sits near the globe's edge, where it's
    /// very sensitive.
    static let horizonMargin = 5 * Double.pi / 180

    /// Where the tilt assist starts, meters above the ellipsoid.
    static let tiltStartAltitude = 50_000.0

    /// 0 up to 50 km, 1 from 500 km, on a smoothstep in log(altitude).
    static func tiltWeight(altitude: Double) -> Double {
        let t = min(max(log(max(altitude, 1) / tiltStartAltitude) / log(10.0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Drone mode's tilt assist for `camera` in `room`: from the
    /// navigation position's height above the ellipsoid, found as if the
    /// ground were the ellipsoid, so the tilt depends on `camera` and
    /// nothing else; a new ground estimate rescales the map but doesn't
    /// turn it. (Terrain shifts the 50–500 km curve negligibly.) On H's
    /// height instead, the tilt would rise faster than the navigation
    /// position as you climb, and the scale would stop shrinking with
    /// height.
    static func tiltWeight(for camera: CameraPose, room: RoomGeometry) -> Double {
        let above = navigationAbove(camera, room: room, groundHeight: 0,
                                    rotation: levelRotation(camera)) { tiltWeight(altitude: $0) }
        return tiltWeight(altitude: above)
    }

    /// The navigation position's height for a stored pose in a room host.
    /// Speeds and climbing follow it, as they did before the stored
    /// altitude became H's.
    struct Lift: Equatable {
        var room: RoomGeometry
        /// The placement ground, meters above the ellipsoid.
        var groundHeight: Double
        var tiltFollowsAltitude: Bool

        private func weight(_ camera: CameraPose) -> Double {
            tiltFollowsAltitude ? tiltWeight(for: camera, room: room) : 0
        }

        func navigationHeight(of camera: CameraPose) -> Double {
            let w = weight(camera)
            return groundHeight + navigationAbove(camera, room: room, groundHeight: groundHeight,
                                                  rotation: levelRotation(camera)) { _ in w }
        }

        func storedHeight(navigationHeight height: Double, at camera: CameraPose) -> Double {
            let eyeHeight = max(room.designEye.y - room.placementLevel.y, 0.01)
            let scale = eyeHeight / max(height - groundHeight, AdaptiveModel.minimumRange)
            return EyeLevelModel.height(forScale: scale, camera: camera, groundHeight: groundHeight, room: room) {
                framing(camera: $0, room: room, groundHeight: groundHeight, tiltWeight: weight($0))
            }
        }
    }

    /// How high above the ground the navigation position is for the framing
    /// to have `scale` (unless a fixed scale is given). For the stored
    /// altitude (H's), see `height(forScale:camera:groundHeight:room:frame:)`.
    static func altitude(forScale scale: Double, room: RoomGeometry) -> Double {
        let eyeHeight = max(room.designEye.y - room.placementLevel.y, 0.01)
        return max(eyeHeight / scale, AdaptiveModel.minimumRange)
    }

    /// The framing for `camera` over ground at `groundHeight` (meters above
    /// the ellipsoid), tilted by `tiltWeight` (0...1) of the host's full
    /// tilt. With `fixedScale` (1 is human scale) the scale stays put and the
    /// ground is wherever the camera's height puts it; otherwise the ground
    /// is on the base plane.
    static func framing(camera: CameraPose, room: RoomGeometry, groundHeight: Double,
                        tiltWeight w: Double, fixedScale: Double? = nil) -> AdaptiveModel.Framing {
        let eye = room.designEye
        let base = room.placementLevel
        let eyeHeight = max(eye.y - base.y, 0.01)
        let rotation = levelRotation(camera)
        let turn = simd_quatd(angle: w * room.fullTilt, axis: SIMD3(1, 0, 0))

        // The navigation position, and its height above the ground.
        let above = navigationAbove(camera, room: room, groundHeight: groundHeight, rotation: rotation) { _ in w }
        let navigation = Geodesy.ecef(camera.coordinate, height: groundHeight + above)
        let scale = fixedScale ?? eyeHeight / above

        // The navigation position on the eye, level, then tilted about the
        // pivot.
        let level = Similarity(scale: scale, rotation: rotation,
                               translation: eye - scale * rotation.act(navigation))
        let pivot = room.tiltPivot(groundBelow: scale * above)
        let tilted = Similarity(translation: pivot)
            .after(Similarity(scale: 1, rotation: turn, translation: .zero))
            .after(Similarity(translation: -pivot))
            .after(level)

        // The ground along the line of sight from the eye.
        let from = tilted.inverse.apply(eye)
        let through = tilted.inverse.apply(eye + room.sightLine(tiltWeight: w))
        let sight = clearOfHorizon(through - from, from: from, groundHeight: groundHeight)
        let georeferencePoint = ground(from: from, toward: from + sight, fallback: camera,
                                       groundHeight: groundHeight)
        return AdaptiveModel.Framing(georeference: Georeference(tilted),
                                     georeferencePoint: georeferencePoint,
                                     placementPoint: tilted.apply(georeferencePoint),
                                     range: simd_distance(georeferencePoint, navigation),
                                     navigation: navigation)
    }

    /// How high above the ground the navigation position is, below
    /// `camera`'s place, for H to be at `camera`'s height, tilted
    /// by `weight` of the full tilt for that height above the ground.
    ///
    /// Turning about the pivot moves H off the navigation position by a
    /// fixed multiple of the navigation position's height above the ground,
    /// whatever the scale (the pivot's offset from H scales with the ground
    /// below it): `offset(w)` per meter, in the level room frame.
    /// So H is at `navigation(a) + a·offset` for height `a` above the
    /// ground, and its height above the ellipsoid rises with `a` as long as
    /// the tilt doesn't fall as `a` rises.
    private static func navigationAbove(_ camera: CameraPose, room: RoomGeometry, groundHeight: Double,
                                        rotation: simd_quatd, weight: (Double) -> Double) -> Double {
        let eye = room.designEye
        let eyeHeight = max(eye.y - room.placementLevel.y, 0.01)
        let toPivot = room.tiltPivot(groundBelow: eyeHeight) - eye
        func offset(_ a: Double) -> SIMD3<Double> {
            let turn = simd_quatd(angle: weight(a) * room.fullTilt, axis: SIMD3(1, 0, 0))
            return (toPivot - turn.inverse.act(toPivot)) / eyeHeight
        }
        let minimum = AdaptiveModel.minimumRange
        func eyeHeightAboveEllipsoid(_ a: Double) -> Double {
            Geodesy.geodetic(Geodesy.ecef(camera.coordinate, height: groundHeight + a)
                             + a * rotation.inverse.act(offset(a))).height
        }
        // Flat ground: H is (1 + offset.y)·a above it.
        let flat = camera.height - groundHeight
        var a = max(flat / max(1 + offset(flat).y, 1e-6), minimum)
        for _ in 0..<12 {
            let miss = eyeHeightAboveEllipsoid(a) - camera.height
            let step = max(a * 1e-6, 1e-3)
            let slope = (eyeHeightAboveEllipsoid(a + step) - eyeHeightAboveEllipsoid(a)) / step
            guard slope > 1e-6 else { break }
            let next = max(a - miss / slope, minimum)
            defer { a = next }
            if abs(next - a) < 1e-9 * max(a, 1) { break }
        }
        return a
    }

    /// The height (H's, above the ellipsoid) at which `frame` shows the
    /// world at `scale`, with `camera`'s place and heading: the inverse of
    /// the framing's scale. `frame` must not fix the scale.
    static func height(forScale scale: Double, camera: CameraPose, groundHeight: Double, room: RoomGeometry,
                       frame: (CameraPose) -> AdaptiveModel.Framing) -> Double {
        var pose = camera
        let lowest = log(AdaptiveModel.minimumRange)
        // Solve in log(height above the ground), where the scale is close to
        // a line of slope −1 (exactly, without tilt).
        var x = log(altitude(forScale: scale, room: room))
        func miss(_ x: Double) -> Double {
            pose.height = groundHeight + exp(x)
            return log(frame(pose).georeference.scale / scale)
        }
        var m = miss(x)
        var slope = -1.0
        for _ in 0..<20 where abs(m) > 1e-12 {
            let next = max(x - m / slope, lowest)
            guard next != x else { break }
            let n = miss(next)
            if n != m { slope = (n - m) / (next - x) }
            if !(slope < -1e-6) { slope = -1 }
            x = next
            m = n
        }
        return groundHeight + exp(x)
    }

    /// `direction` (ECEF) from `origin`, dipped further if it has to be to
    /// stay `horizonMargin` below the horizon of the ground at `groundHeight`
    /// seen from `origin`. The dip is below `origin`'s level, and the
    /// horizon is a sphere's through the ground below, which is within a
    /// fraction of a degree of the ellipsoid's.
    static func clearOfHorizon(_ direction: SIMD3<Double>, from origin: SIMD3<Double>,
                               groundHeight: Double) -> SIMD3<Double> {
        let distance = simd_length(origin), length = simd_length(direction)
        guard distance > 0, length > 0 else { return direction }
        let up = origin / distance
        let unit = direction / length
        let above = max(Geodesy.geodetic(origin).height - groundHeight, 0)
        let horizonDip = acos(min(max((distance - above) / distance, 0), 1))
        let least = min(horizonDip + horizonMargin, .pi / 2)
        let dip = asin(min(max(-simd_dot(unit, up), -1), 1))
        guard dip < least else { return direction }
        let level = unit - simd_dot(unit, up) * up
        guard simd_length(level) > 1e-12 else { return -up * length }
        return (simd_normalize(level) * cos(least) - up * sin(least)) * length
    }

    /// Where the ray from `origin` through `point` (both ECEF) meets the
    /// ground, or the ground beneath `fallback` if it doesn't.
    private static func ground(from origin: SIMD3<Double>, toward point: SIMD3<Double>, fallback: CameraPose,
                               groundHeight: Double) -> SIMD3<Double> {
        let ray = Ray(origin: origin, direction: point - origin)
        if case let .hit(hit, _) = Geodesy.intersect(ray: ray, surfaceHeight: groundHeight) { return hit }
        return Geodesy.ecef(fallback.coordinate, height: groundHeight)
    }

    /// Level: the camera's local up is the room's up, its heading faces −z.
    static func levelRotation(_ camera: CameraPose) -> simd_quatd {
        let frame = Geodesy.enu(latitude: camera.latitude, longitude: camera.longitude)
        let forward = frame.north * cos(camera.heading) + frame.east * sin(camera.heading)
        let right = frame.east * cos(camera.heading) - frame.north * sin(camera.heading)
        return simd_quatd(simd_double3x3(rows: [right, frame.up, -forward]))
    }

    /// A pose framing a place: `radius` meters of world across the content
    /// half-width, facing `heading`, with the center (at `groundHeight`) as
    /// the view center. Tilted as the assist would at that height when
    /// `tiltFollowsAltitude`. Its pitch looks at the center; placement
    /// ignores it.
    static func framePlace(center: GeoCoordinate, radius: Double, heading: Double,
                           room: RoomGeometry, groundHeight: Double = 0,
                           tiltFollowsAltitude: Bool = true) -> CameraPose {
        let scale = room.contentHalfWidth / max(radius, 1)
        let eye = room.designEye
        func frame(_ camera: CameraPose) -> AdaptiveModel.Framing {
            framing(camera: camera, room: room, groundHeight: groundHeight,
                    tiltWeight: tiltFollowsAltitude ? tiltWeight(for: camera, room: room) : 0)
        }
        let height = Self.height(forScale: scale,
                                 camera: CameraPose(latitude: center.latitude, longitude: center.longitude,
                                                    height: 0, heading: heading, pitch: 0),
                                 groundHeight: groundHeight, room: room, frame: frame)
        // Start with the level view center this far ahead of the eye on the
        // base plane, in world meters.
        let level = room.levelViewCenter
        let ahead = simd_length(SIMD2(level.x - eye.x, level.z - eye.z)) / scale
        let start = GeoMath.destination(from: center, bearing: heading + .pi, distance: ahead)
        let target = Geodesy.ecef(center, height: groundHeight)
        return standpoint(viewing: target, from: start, iterations: 6, frame: frame) { point in
            let distance = GeoMath.distance(from: point, to: center)
            return CameraPose(latitude: point.latitude, longitude: point.longitude, height: height,
                              heading: NavigationOperations.wrapped(heading + GeoMath.bearingChange(from: center, to: point)),
                              pitch: -atan2(height - groundHeight, max(distance, 1e-6)))
        }
    }

    /// `camera` moved to `height` (meters above the ellipsoid) with its view
    /// center where it was: zoom in a room host. The heading relative to the
    /// view center and the pitch are kept. The pose is a function of the view
    /// center and the height alone, so zooming out and back in to the same
    /// height returns to the same view.
    static func pose(_ camera: CameraPose, at height: Double,
                     holdingViewCenter frame: (CameraPose) -> AdaptiveModel.Framing) -> CameraPose {
        let target = frame(camera).georeferencePoint
        let center = Geodesy.geodetic(target).coordinate
        let heading = camera.heading - GeoMath.bearingChange(from: center, to: camera.coordinate)
        // Start where the camera would be if the view center's distance
        // scaled with the height above it.
        let centerHeight = Geodesy.geodetic(target).height
        let ratio = max(height - centerHeight, 1e-6) / max(camera.height - centerHeight, 1e-6)
        let start = GeoMath.destination(from: center, bearing: GeoMath.bearing(from: center, to: camera.coordinate),
                                        distance: GeoMath.distance(from: center, to: camera.coordinate) * ratio)
        return standpoint(viewing: target, from: start, iterations: 20, frame: frame) { point in
            CameraPose(latitude: point.latitude, longitude: point.longitude, height: height,
                       heading: NavigationOperations.wrapped(heading + GeoMath.bearingChange(from: center, to: point)),
                       pitch: camera.pitch)
        }
    }

    /// Nudges the standpoint, starting at `start`, until `target` (ECEF) is
    /// the view center of `pose(standpoint)`.
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
