import Foundation
import simd

/// A window onto the camera, for turning screen points into rays: its size
/// in points (y down) and its vertical field of view.
struct ScreenViewport: Equatable {
    var size: SIMD2<Double>
    var fieldOfView: Double

    var aspect: Double { size.x / max(size.y, 1) }
    var centre: SIMD2<Double> { size / 2 }
}

/// Direct manipulation on a flat screen: the ground you touch stays under
/// your finger. Pure functions of the navigation state; the ground is the
/// surface at the camera ground estimate, not the tiles themselves, so tall
/// buildings slide a little under a finger.
enum ScreenGestures {
    /// How far below the horizon the lowest usable ray is, radians. Points
    /// nearer the horizon, or in the sky, use this ray instead, so a small
    /// finger move there can't mean hundreds of kilometres.
    static let horizonMargin = 1.5 * Double.pi / 180
    /// The levelest view tilting reaches, radians.
    static let levelestTilt = -3 * Double.pi / 180

    /// The ray from the camera through a screen point.
    static func ray(camera: CameraPose, point: SIMD2<Double>, viewport: ScreenViewport) -> Ray {
        let basis = camera.basis
        let halfHeight = tan(viewport.fieldOfView / 2)
        let x = (2 * point.x / max(viewport.size.x, 1) - 1) * halfHeight * viewport.aspect
        let y = (1 - 2 * point.y / max(viewport.size.y, 1)) * halfHeight
        return Ray(origin: camera.position,
                   direction: simd_normalize(basis.forward + basis.right * x + basis.up * y))
    }

    /// The ground under a screen point (ECEF). Near the horizon or in the
    /// sky, the ground the lowest usable ray reaches in that direction.
    static func groundPoint(camera: CameraPose, point: SIMD2<Double>, viewport: ScreenViewport,
                            groundHeight: Double) -> SIMD3<Double>? {
        var ray = ray(camera: camera, point: point, viewport: viewport)
        let up = Geodesy.enu(latitude: camera.latitude, longitude: camera.longitude).up
        let altitude = max(camera.height - groundHeight, 1)
        let radius = GeoMath.earthRadius
        let lowest = acos(radius / (radius + altitude)) + horizonMargin
        if asin(min(max(-simd_dot(ray.direction, up), -1), 1)) < lowest {
            let level = ray.direction - simd_dot(ray.direction, up) * up
            guard simd_length(level) > 1e-9 else { return nil }
            ray.direction = simd_normalize(level) * cos(lowest) - up * sin(lowest)
        }
        guard case let .hit(hit, _) = Geodesy.intersect(ray: ray, surfaceHeight: groundHeight) else { return nil }
        return hit
    }

    /// Moves the camera, keeping its height and view, so `grab` (ECEF, on
    /// the ground) is under the screen point.
    static func pan(_ state: NavigationState, grab: SIMD3<Double>, to point: SIMD2<Double>,
                    viewport: ScreenViewport, groundHeight: Double) -> NavigationState {
        var state = state
        // The Earth curves under a long drag; a few steps settle it.
        for _ in 0..<3 {
            guard let hit = groundPoint(camera: state.camera, point: point, viewport: viewport,
                                        groundHeight: groundHeight)
            else { break }
            let (forward, right) = alongMovement(state, grab - hit)
            state = NavigationOperations.move(state, forward: forward, right: right)
        }
        return state
    }

    /// An ECEF offset as metres forward and right of the movement heading.
    static func alongMovement(_ state: NavigationState, _ offset: SIMD3<Double>) -> (forward: Double, right: Double) {
        let frame = Geodesy.enu(latitude: state.camera.latitude, longitude: state.camera.longitude)
        let east = simd_dot(offset, frame.east), north = simd_dot(offset, frame.north)
        let heading = state.movementHeading
        return (north * cos(heading) + east * sin(heading), east * cos(heading) - north * sin(heading))
    }

    /// Scales the view about `pivot` (ECEF): `scale` 2 is half as far away.
    static func zoom(_ state: NavigationState, about pivot: SIMD3<Double>, scale: Double,
                     context: NavigationContext) -> NavigationState {
        NavigationOperations.dolly(state, toward: pivot, fraction: 1 - 1 / max(scale, 1e-3), context: context)
    }
}

/// Tells the two-finger gestures apart: both fingers moving up or down
/// together tilts, anything else (pinching, twisting, sliding sideways) is
/// the map following the fingers. Decided once per gesture, on the first
/// clear movement, so a tilt doesn't turn into a zoom halfway through.
struct TwoFingerClassifier: Equatable {
    enum Mode: Equatable { case undecided, tilt, follow }
    private(set) var mode = Mode.undecided

    /// Points the fingers must move together to count.
    static let slide = 14.0
    /// A change of spacing or angle this big is a pinch or a twist.
    static let pinch = 0.06
    static let twist = 0.08

    /// `translation` is how far the fingers' midpoint has moved, in points
    /// (y down); `scale` and `rotation` their spacing and angle since the
    /// gesture began.
    mutating func update(translation: SIMD2<Double>, scale: Double, rotation: Double) -> Mode {
        guard mode == .undecided else { return mode }
        if abs(scale - 1) > Self.pinch || abs(rotation) > Self.twist {
            mode = .follow
        } else if abs(translation.y) > Self.slide, abs(translation.y) > 2 * abs(translation.x) {
            mode = .tilt
        } else if abs(translation.x) > Self.slide {
            mode = .follow
        }
        return mode
    }
}
