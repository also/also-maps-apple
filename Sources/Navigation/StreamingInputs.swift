import Foundation
import simd

/// The origin of the bridge's anchor frame A, where it places every tile:
/// RealityKit axes (x east, y up, z south), meters, the anchor at 0.
struct StreamingAnchor: Codable, Equatable {
    var coordinate: GeoCoordinate
    /// Meters above the WGS84 ellipsoid.
    var height = 0.0

    /// Anchor frame → ECEF.
    var ecefFromAnchor: Similarity {
        let rotation = Geodesy.anchorFrameRotation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return Similarity(scale: 1,
                          rotation: simd_quatd(rotation),
                          translation: Geodesy.ecef(coordinate, height: height))
    }
}

/// The view frustum level of detail is selected for (the culling camera),
/// in anchor frame A.
struct LODCamera: Codable, Equatable {
    var position = SIMD3<Double>(0, 849, 849)
    /// Unit.
    var direction = SIMD3<Double>(0, -0.5.squareRoot(), -0.5.squareRoot())
    /// Unit, perpendicular to `direction`.
    var up = SIMD3<Double>(0, 0.5.squareRoot(), -0.5.squareRoot())
    /// Vertical field of view, radians.
    var fieldOfView = Double.pi / 3
    /// Width over height.
    var aspect = 1.0

    /// Looking at the anchor from `distance` meters away, `elevation`
    /// radians above its horizon, facing `heading` (radians clockwise from
    /// north). Direction and up are written down directly so they stay
    /// perpendicular unit vectors at any elevation, straight down included.
    static func orbit(heading: Double, elevation: Double, distance: Double) -> LODCamera {
        let elevation = min(max(elevation, 0.05), .pi / 2)
        let sinHeading = sin(heading), cosHeading = cos(heading)
        let sinElevation = sin(elevation), cosElevation = cos(elevation)
        // East, north, up → frame A (x east, y up, z south).
        let direction = SIMD3(sinHeading * cosElevation, -sinElevation, -cosHeading * cosElevation)
        let up = SIMD3(sinHeading * sinElevation, cosElevation, -cosHeading * sinElevation)
        return LODCamera(position: -direction * distance, direction: direction, up: up)
    }
}

/// What cesium-native is told: where tiles are placed from, what's eligible
/// to stream and the frustum detail is chosen for. Follows the camera while
/// tiles are live; frozen while held.
struct StreamingInputs: Codable, Equatable {
    /// The area of interest's center, and frame A's origin.
    var anchor: StreamingAnchor
    var lod = LODCamera()
    /// Rotation of the area of interest's square, radians clockwise from north.
    var regionHeading = 0.0
    /// Half-width of the area of interest, meters.
    var streamingRadius = 500.0
}

extension StreamingInputs {
    /// A room host's streaming inputs for `framing`: the area of interest
    /// from `policy`, anchored at `groundHeight`, and the LOD camera at the
    /// design eye point. The viewer is the eye, wherever the tilt has put it
    /// in the world, at its altitude over `groundHeight`.
    static func room(framing: AdaptiveModel.Framing, room: RoomGeometry, camera: CameraPose, policy: AOIPolicy,
                     groundHeight: Double) -> StreamingInputs {
        let viewer = Geodesy.geodetic(framing.eye(room))
        let area = policy.area(viewerNadir: viewer.coordinate,
                               altitude: max(viewer.height - groundHeight, 0),
                               heading: camera.heading,
                               georeferencePoint: Geodesy.geodetic(framing.georeferencePoint).coordinate,
                               shownRadius: framing.shownRadius(room))
        let anchor = StreamingAnchor(coordinate: area.center, height: groundHeight)
        return StreamingInputs(anchor: anchor,
                               lod: AdaptiveModel.lodCamera(framing: framing, eye: room.designEye, anchor: anchor),
                               regionHeading: area.heading,
                               streamingRadius: area.radius)
    }
}
