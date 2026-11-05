import Foundation
import simd

/// The user's nudges to a photo's pose, radians, for lining it up with the
/// scene: EXIF has no pitch or roll, and compass headings are often off by
/// a few degrees.
struct PhotoAdjustment: Equatable {
    var heading = 0.0
    var pitch = 0.0

    static let none = PhotoAdjustment()
}

/// Where the photographer's eye was, and the camera pose that stands there
/// looking the way the camera did. See notes/photos-in-place.md.
enum PhotoPose {
    /// Eye height above the ground beneath the photo, metres.
    static let eyeAboveGround = 1.6
    /// How far above the sampled ground the recorded altitude must be before
    /// it's believed instead: GPS altitude is above sea level, not the
    /// ellipsoid, so it can be ~100 m off the ground by the geoid alone,
    /// and it's often tens of metres off besides. Only a photo clearly taken
    /// from high up (a tower, a hill the tiles don't show, a drone) clears it.
    static let elevatedThreshold = 120.0

    enum EyeSource: Equatable {
        /// The sampled ground plus `eyeAboveGround`.
        case ground
        /// The recorded altitude, used as height above the ellipsoid.
        case recorded
    }

    /// The eye's height above the ellipsoid, metres, from the ground beneath
    /// the photo (sampled at runtime, never saved) and the recorded
    /// altitude. Without a ground sample the recorded altitude stands in;
    /// with neither there's no height.
    static func eyeHeight(ground: Double?, recordedAltitude: Double?) -> (height: Double, source: EyeSource)? {
        switch (ground, recordedAltitude) {
        case let (ground?, recorded?) where recorded - ground > elevatedThreshold:
            (recorded, .recorded)
        case let (ground?, _):
            (ground + eyeAboveGround, .ground)
        case let (nil, recorded?):
            (recorded, .recorded)
        case (nil, nil):
            nil
        }
    }

    /// The camera standing where the photo was taken, looking the way it
    /// faced (north if it didn't record a direction), level unless nudged.
    /// Nil without a location or any height.
    static func camera(_ metadata: PhotoMetadata, ground: Double?,
                       adjustment: PhotoAdjustment = .none) -> CameraPose? {
        guard let latitude = metadata.latitude, let longitude = metadata.longitude,
              let eye = eyeHeight(ground: ground, recordedAltitude: metadata.altitude)
        else { return nil }
        let heading = PhotoGeometry.heading(metadata)?.heading ?? 0
        let limit = Double.pi / 2 - 0.01
        return CameraPose(latitude: latitude, longitude: longitude, height: eye.height,
                          heading: NavigationOperations.wrapped(heading + adjustment.heading),
                          pitch: min(max(adjustment.pitch, -limit), limit))
    }

    // MARK: Showing the photo

    /// The photo's size, metres, as a frame `distance` metres straight
    /// ahead of the eye that subtends its field of view exactly.
    static func frameSize(_ fieldOfView: PhotoFieldOfView, distance: Double) -> (width: Double, height: Double) {
        (2 * distance * tan(fieldOfView.horizontal / 2), 2 * distance * tan(fieldOfView.vertical / 2))
    }

    /// The photo's size in points over a window whose camera has a vertical
    /// field of view of `windowFieldOfView` and is `viewportHeight` points
    /// tall, centred on its view direction, so it lines up with the scene.
    static func screenSize(_ fieldOfView: PhotoFieldOfView, windowFieldOfView: Double,
                           viewportHeight: Double) -> (width: Double, height: Double) {
        let pointsPerTangent = viewportHeight / 2 / tan(windowFieldOfView / 2)
        return (2 * pointsPerTangent * tan(fieldOfView.horizontal / 2),
                2 * pointsPerTangent * tan(fieldOfView.vertical / 2))
    }

    /// A window's vertical field of view that shows the whole photo with
    /// `margin` (a fraction of it) to spare in a viewport of `aspect` (width
    /// over height), and never narrower than `minimum`, radians.
    static func windowFieldOfView(toShow fieldOfView: PhotoFieldOfView, aspect: Double,
                                  margin: Double = 0.1, minimum: Double, maximum: Double = 2.1) -> Double {
        let scale = 1 + margin
        let byHeight = tan(fieldOfView.vertical / 2) * scale
        let byWidth = tan(fieldOfView.horizontal / 2) * scale / max(aspect, 0.01)
        let needed = 2 * atan(max(byHeight, byWidth))
        return min(max(needed, minimum), maximum)
    }

    // MARK: Markers

    /// Unit vectors at a photo, ECEF: level right of its heading, local up,
    /// and back toward the photographer. A marker's photo lies in right and
    /// up, facing back, so it reads as it did through the viewfinder when
    /// you stand behind it looking the same way.
    static func markerBasis(latitude: Double, longitude: Double, heading: Double)
        -> (right: SIMD3<Double>, up: SIMD3<Double>, back: SIMD3<Double>) {
        let frame = Geodesy.enu(latitude: latitude, longitude: longitude)
        let forward = frame.north * cos(heading) + frame.east * sin(heading)
        let right = frame.east * cos(heading) - frame.north * sin(heading)
        return (right, frame.up, -forward)
    }

    /// The rotation taking a marker's local axes (x right, y up, z back:
    /// RealityKit's plane facing +z) to ECEF.
    static func markerRotation(latitude: Double, longitude: Double, heading: Double) -> simd_quatd {
        let basis = markerBasis(latitude: latitude, longitude: longitude, heading: heading)
        return simd_quatd(simd_double3x3(columns: (basis.right, basis.up, basis.back)))
    }
}
