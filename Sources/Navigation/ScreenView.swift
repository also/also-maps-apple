import Foundation
import simd

/// A flat screen's presentation (macOS, iOS): the window's camera is the
/// navigation camera, so there's no placement to choose. The scene is the
/// camera's local level frame (x east, y up, z south, meters) with the
/// camera at its origin, so only nearby numbers reach Float; the camera
/// entity turns by the pose's heading and pitch.
enum ScreenView {
    /// ECEF → scene: the camera at the origin, unscaled.
    static func georeference(camera: CameraPose) -> Georeference {
        let frame = Geodesy.enu(latitude: camera.latitude, longitude: camera.longitude)
        let rotation = simd_quatd(simd_double3x3(rows: [frame.east, frame.up, -frame.north]))
        return Georeference(scale: 1, rotation: rotation, translation: -rotation.act(camera.position))
    }

    /// The camera entity's orientation in the scene: it looks down its −z,
    /// with no roll.
    static func cameraOrientation(camera: CameraPose) -> simd_quatd {
        let toScene = georeference(camera: camera).rotation
        let basis = camera.basis
        let forward = toScene.act(basis.forward), right = toScene.act(basis.right), up = toScene.act(basis.up)
        return simd_quatd(simd_double3x3(columns: (right, up, -forward)))
    }

    /// What to stream: everything visible out to the horizon around the
    /// camera, anchored on the ground beneath it, with level of detail
    /// chosen for the camera itself.
    static func streamingInputs(camera: CameraPose, groundHeight: Double,
                                fieldOfView: Double, aspect: Double) -> StreamingInputs {
        let altitude = max(camera.height - groundHeight, 0)
        let area = AOIPolicy.horizon(limitPerAltitude: nil)
            .area(viewerNadir: camera.coordinate, altitude: altitude, heading: camera.heading,
                  georeferencePoint: camera.coordinate, shownRadius: 0)
        let anchor = StreamingAnchor(coordinate: area.center, height: groundHeight)
        let toAnchor = anchor.ecefFromAnchor.inverse
        let basis = camera.basis
        let lod = LODCamera(position: toAnchor.apply(camera.position),
                            direction: simd_normalize(toAnchor.rotation.act(basis.forward)),
                            up: simd_normalize(toAnchor.rotation.act(basis.up)),
                            fieldOfView: fieldOfView, aspect: aspect)
        return StreamingInputs(anchor: anchor, lod: lod, regionHeading: area.heading,
                               streamingRadius: area.radius)
    }

    /// Near and far clip distances, meters: near grows with altitude so
    /// depth precision follows what's in view, and far reaches the horizon.
    static func clipping(altitude: Double) -> (near: Double, far: Double) {
        let altitude = max(altitude, 0)
        let near = min(max(altitude * 0.01, 0.2), 100)
        let far = max(AOIPolicy.visibleDistance(altitude: altitude) * 1.2, 10_000)
        return (near, far)
    }

    /// How far places are looked down on: shallow, like a drone shot, so
    /// the horizon is in view.
    static let placeElevation = 12 * Double.pi / 180

    /// A pose looking at `center` (on ground at `groundHeight`) from
    /// `elevation` radians above its horizon, facing `heading`, far enough
    /// back that `radius` meters around it fill the view.
    static func framePlace(center: GeoCoordinate, radius: Double, heading: Double,
                           groundHeight: Double = 0, elevation: Double = placeElevation,
                           fieldOfView: Double = .pi / 4) -> CameraPose {
        let target = Geodesy.ecef(center, height: groundHeight)
        let frame = Geodesy.enu(latitude: center.latitude, longitude: center.longitude)
        let level = frame.north * cos(heading) + frame.east * sin(heading)
        let forward = level * cos(elevation) - frame.up * sin(elevation)
        let distance = max(radius, 1) / tan(fieldOfView / 2)
        return CameraPose(position: target - forward * distance, forward: forward, fallbackHeading: heading)
    }
}
