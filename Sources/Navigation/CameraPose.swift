import Foundation
import simd

/// A geographic viewpoint: where the camera is and which way it looks.
/// Movement heading and control-style state are kept separately
/// (NavigationState), and tracked head offsets are applied on top.
struct CameraPose: Codable, Equatable {
    var latitude: Double      // degrees
    var longitude: Double     // degrees
    /// Metres above the WGS84 ellipsoid.
    var height: Double
    /// Radians clockwise from local north at the camera.
    var heading: Double
    /// Radians: 0 level, −π/2 straight down, + up.
    var pitch: Double

    var coordinate: GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    var position: SIMD3<Double> {
        Geodesy.ecef(latitude: latitude, longitude: longitude, height: height)
    }

    /// The camera's forward, right and up, ECEF. Right stays level (no roll).
    var basis: (forward: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>) {
        let frame = Geodesy.enu(latitude: latitude, longitude: longitude)
        let forward = frame.east * (sin(heading) * cos(pitch))
            + frame.north * (cos(heading) * cos(pitch))
            + frame.up * sin(pitch)
        let right = frame.east * cos(heading) - frame.north * sin(heading)
        return (forward, right, simd_cross(right, forward))
    }

    /// The pose at `position` looking along `forward` (ECEF); heading and
    /// pitch are measured in the local frame there. Looking straight up or
    /// down, `fallbackHeading` is kept.
    init(position: SIMD3<Double>, forward: SIMD3<Double>, fallbackHeading: Double = 0) {
        let (coordinate, height) = Geodesy.geodetic(position)
        let frame = Geodesy.enu(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let f = simd_normalize(forward)
        let east = simd_dot(f, frame.east), north = simd_dot(f, frame.north)
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.height = height
        self.heading = (east * east + north * north) > 1e-20 ? atan2(east, north) : fallbackHeading
        self.pitch = asin(min(max(simd_dot(f, frame.up), -1), 1))
    }

    init(latitude: Double, longitude: Double, height: Double, heading: Double, pitch: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
        self.heading = heading
        self.pitch = pitch
    }
}

/// Whether movement heading follows view heading. Model flight links them:
/// every change to the view heading is applied to the movement heading too.
/// A drone style keeps them independent.
enum HeadingLink: String, Codable {
    case linked
    case independent
}

/// The geographic navigation state shared by every control style. Concrete
/// style state (an orbit pivot, say) is owned by the style.
struct NavigationState: Codable, Equatable {
    var camera: CameraPose
    /// Radians clockwise from local north at the camera: the direction
    /// forward/right movement controls use.
    var movementHeading: Double
    /// Set by the control style when it activates.
    var headingLink: HeadingLink

    init(camera: CameraPose, movementHeading: Double? = nil, headingLink: HeadingLink = .linked) {
        self.camera = camera
        self.movementHeading = movementHeading ?? camera.heading
        self.headingLink = headingLink
    }
}
