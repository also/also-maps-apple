import Foundation

/// A camera following a moving point from behind and above, as in a race
/// replay. Its heading eases toward the direction of travel, so GPS wander
/// and the corners of a recorded line don't make it wobble, and the
/// point's height eases too, so a noisy height doesn't make it bob.
///
/// It gives the camera pose only. Each host shows that pose as it shows any
/// other: on a screen it's the window's camera, and in the immersive space
/// it's the eye (docs/navigation-handoff.md: the camera is always the eye),
/// so the chase never puts the camera anywhere the viewer isn't.
struct ChaseCamera: Equatable {
    /// Metres behind the point, along the ground.
    var distance: Double
    /// Metres above the point.
    var height: Double
    /// Seconds of wall-clock time for the heading to turn halfway to a new
    /// direction of travel.
    var headingHalfLife = 1.0
    /// The same for the point's height.
    var heightHalfLife = 0.5
    /// Off: the heading stays where the chase started, and the camera just
    /// trails the point, which turns the world less in a headset.
    var turnsWithTravel = true

    /// Radians clockwise from north; nil until the first pose.
    private(set) var heading: Double?
    private var pointHeight: Double?

    init(distance: Double, height: Double) {
        self.distance = distance
        self.height = height
    }

    /// Far enough back to see where the route goes next at its usual speed:
    /// about 20 s of travel (60 m for a run, 150 m for a ride, a few km for
    /// a flight), looking down at about 22°.
    init(typicalSpeed: Double) {
        let distance = min(max(20 * typicalSpeed, 60), 3_000)
        self.init(distance: distance, height: 0.4 * distance)
    }

    /// Forgets the heading and height, so the next pose snaps to the point.
    mutating func reset() {
        heading = nil
        pointHeight = nil
    }

    /// The camera for this frame, chasing a point at `point` and `height`
    /// metres above the ellipsoid, travelling toward `travelHeading` (nil
    /// keeps the last heading, as when stopped).
    mutating func pose(following point: GeoCoordinate, height: Double, travelHeading: Double?,
                       deltaTime: Double) -> CameraPose {
        let goal = travelHeading ?? heading ?? 0
        if let current = heading {
            if turnsWithTravel {
                let f = Self.easing(deltaTime, halfLife: headingHalfLife)
                heading = NavigationOperations.wrapped(current + remainder(goal - current, 2 * .pi) * f)
            }
        } else {
            heading = NavigationOperations.wrapped(goal)
        }
        if let current = pointHeight {
            pointHeight = current + (height - current) * Self.easing(deltaTime, halfLife: heightHalfLife)
        } else {
            pointHeight = height
        }
        let heading = self.heading!, pointHeight = self.pointHeight!

        let behind = GeoMath.destination(from: point, bearing: heading + .pi, distance: distance)
        let camera = Geodesy.ecef(behind, height: pointHeight + self.height)
        let target = Geodesy.ecef(point, height: pointHeight)
        return CameraPose(position: camera, forward: target - camera, fallbackHeading: heading)
    }

    /// The fraction of the way to go in `deltaTime` for a half-life.
    static func easing(_ deltaTime: Double, halfLife: Double) -> Double {
        guard halfLife > 0 else { return 1 }
        return 1 - pow(0.5, max(deltaTime, 0) / halfLife)
    }
}
