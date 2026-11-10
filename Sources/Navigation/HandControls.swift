import Foundation
import simd

// Hand-tracked controls for the Metal immersive space: the gesture and
// geometry logic, without ARKit. MetalImmersiveSpace feeds it hand
// skeletons each frame and applies what it returns to the MapModel.
// Everything here is in the immersive space's coordinates (metres, y up),
// which is the scene space the map's gestures use.

/// The hand-tracked control scheme for the Metal immersive space
/// (Settings › Immersion). Standard look-and-pinch is separate.
enum HandControlScheme: String, CaseIterable, Identifiable {
    case none
    /// Point with one hand; pinch with the other to fly to where the ray
    /// meets the map.
    case pointAndJump
    /// Make a fist to grab the map and drag it; two fists also zoom and turn.
    case grabWorld
    /// Point with one hand; close the other hand's pinch to fly along the
    /// ray, faster the tighter the pinch.
    case pointToFly

    var id: Self { self }

    static let storageKey = "HandControlScheme"

    /// The saved choice, or ALSOMAPS_HAND_CONTROLS=<rawValue> for a run.
    static var current: HandControlScheme {
        let raw = ProcessInfo.processInfo.environment["ALSOMAPS_HAND_CONTROLS"]
            ?? UserDefaults.standard.string(forKey: storageKey)
        return raw.flatMap(HandControlScheme.init(rawValue:)) ?? .none
    }

    var title: String {
        switch self {
        case .none: "None"
        case .pointAndJump: "Point and jump"
        case .grabWorld: "Grab the world"
        case .pointToFly: "Point to fly"
        }
    }

    var summary: String {
        switch self {
        case .none: "No hand-tracked controls; controllers and the keyboard still work."
        case .pointAndJump: "Point with one hand: a ray shows where it meets the map. Pinch with the other hand to fly there."
        case .grabWorld: "Make a fist to grab the map and drag it. With both fists, move them apart or together to zoom, and turn them to rotate."
        case .pointToFly: "Point with one hand, then pinch with the other to fly along the ray: the tighter the pinch, the faster."
        }
    }

    /// Whether the scheme needs hand tracking at all.
    var usesHands: Bool { self != .none }
}

/// The joints the schemes use from one tracked hand, in the immersive space.
struct HandJoints: Equatable {
    /// One finger's joints from the knuckle out.
    struct Finger: Equatable {
        var knuckle: SIMD3<Float>
        var intermediateBase: SIMD3<Float>
        var intermediateTip: SIMD3<Float>
        var tip: SIMD3<Float>

        /// Knuckle-to-tip distance over the length along the joints: about 1
        /// straight, falling as the finger curls. Independent of hand size.
        var straightness: Float {
            let along = simd_distance(knuckle, intermediateBase) + simd_distance(intermediateBase, intermediateTip)
                + simd_distance(intermediateTip, tip)
            guard along > 1e-4 else { return 0 }
            return simd_distance(knuckle, tip) / along
        }

        /// A straight finger's pointing direction, knuckle to tip.
        var direction: SIMD3<Float> { simd_normalize(tip - knuckle) }
    }

    var wrist: SIMD3<Float>
    var thumbTip: SIMD3<Float>
    var index: Finger
    var middle: Finger
    var ring: Finger
    var little: Finger

    /// Thumb tip to index tip, metres.
    var pinchDistance: Float { simd_distance(thumbTip, index.tip) }

    /// Where a grabbing hand holds the world: the middle knuckle, the
    /// steadiest point of a fist.
    var grabPoint: SIMD3<Float> { middle.knuckle }

    /// The mean straightness of the three fingers that curl when pointing.
    var otherFingersStraightness: Float { (middle.straightness + ring.straightness + little.straightness) / 3 }

    /// The straighter of the index and the other three (mean): low only
    /// when all four are curled, as in a fist.
    var openness: Float { max(index.straightness, otherFingersStraightness) }
}

/// A two-state detector with separate thresholds to enter and leave, so a
/// value near one threshold doesn't flicker.
struct Hysteresis: Equatable {
    /// Enters below `enter`, leaves above `leave` (enter < leave).
    var enter: Float
    var leave: Float
    private(set) var isOn = false

    init(enter: Float, leave: Float) {
        self.enter = enter
        self.leave = leave
    }

    /// Updates with a new value; nil (not tracked) turns it off.
    @discardableResult
    mutating func update(_ value: Float?) -> Bool {
        guard let value else {
            isOn = false
            return false
        }
        isOn = isOn ? value < leave : value < enter
        return isOn
    }
}

/// One hand's recognised poses, with hysteresis.
struct HandPoseDetector: Equatable {
    /// Thumb and index tips within 1.5 cm pinch; apart past 3 cm releases.
    var pinch = Hysteresis(enter: 0.015, leave: 0.03)
    /// All four fingers curled.
    var fist = Hysteresis(enter: 0.62, leave: 0.75)
    private(set) var isPointing = false

    mutating func update(_ hand: HandJoints?) {
        pinch.update(hand?.pinchDistance)
        fist.update(hand?.openness)
        guard let hand else {
            isPointing = false
            return
        }
        // High when the index is straight and the other three are curled.
        // Starts pointing above 0.88, stops below 0.72.
        let score = min(hand.index.straightness, 1.5 - hand.otherFingersStraightness)
        isPointing = score > (isPointing ? 0.72 : 0.88)
        // A fist isn't a point, and a pinching index isn't pointing.
        if fist.isOn || pinch.isOn { isPointing = false }
    }

    var isPinching: Bool { pinch.isOn }
    var isFist: Bool { fist.isOn }
}

/// A ray in the immersive space, `direction` unit length.
struct HandRay: Equatable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>

    func point(at distance: Float) -> SIMD3<Float> { origin + direction * distance }
}

/// Exponential smoothing of a pointing ray: fingertip rays jitter, and the
/// jitter is magnified with distance. `timeConstant` seconds.
struct RaySmoother: Equatable {
    var timeConstant: Float = 0.08
    private(set) var ray: HandRay?

    init(timeConstant: Float = 0.08) {
        self.timeConstant = timeConstant
    }

    mutating func update(_ new: HandRay?, deltaTime: Float) -> HandRay? {
        guard let new else {
            ray = nil
            return nil
        }
        guard let old = ray else {
            ray = new
            return new
        }
        let k = 1 - exp(-max(deltaTime, 0) / max(timeConstant, 1e-4))
        let direction = old.direction + (new.direction - old.direction) * k
        let smoothed = HandRay(origin: old.origin + (new.origin - old.origin) * k,
                               direction: simd_length(direction) > 1e-6 ? simd_normalize(direction) : new.direction)
        ray = smoothed
        return smoothed
    }
}

enum Chirality: Equatable {
    case left, right

    var other: Chirality { self == .left ? .right : .left }
}

/// What a frame of hand input asks of the map.
enum HandAction: Equatable {
    /// Fly to where the pointer meets the map.
    case jumpToPointer
    /// One or two hands holding the map: `start` and `current` are scene
    /// positions (the grab's midpoint with two hands). With two hands,
    /// `magnification` is the hands' spread over its start and `twist` the
    /// turn of the line between them about +y since the start, radians
    /// (counterclockwise seen from above).
    case grab(start: SIMD3<Float>, current: SIMD3<Float>, magnification: Double?, twist: Double?)
    /// The grab ended (or changed from one hand to two, which restarts it).
    case endGrab
    /// Steer as a controller would.
    case steer(ControlInput)
}

/// What to show for the hands this frame.
struct HandOverlay: Equatable {
    /// The pointing ray, if a hand points.
    var pointer: HandRay?
    /// The pointer hand's other hand is pinching (jump), or its throttle
    /// (fly), 0...1: brightens the ray.
    var emphasis: Float = 0
    /// Grabbing hands.
    var grabs: [SIMD3<Float>] = []
}

/// The schemes' state machine: hands in, actions and overlay out.
struct HandControlController {
    var scheme: HandControlScheme
    private var left = HandPoseDetector()
    private var right = HandPoseDetector()
    private var smoother = RaySmoother()
    private var pointerHand: Chirality?
    private var wasPinching: [Chirality: Bool] = [:]
    private var grab: GrabState?

    private struct GrabState {
        /// Which hands, and where they held at the start.
        var left: SIMD3<Float>?
        var right: SIMD3<Float>?
        var hands: Int { (left == nil ? 0 : 1) + (right == nil ? 0 : 1) }
    }

    init(scheme: HandControlScheme) {
        self.scheme = scheme
    }

    /// Throttle from the pinch: 0 at 6 cm apart, 1 from 1.5 cm (closed).
    static func throttle(pinchDistance: Float) -> Float {
        min(max((0.06 - pinchDistance) / 0.045, 0), 1)
    }

    /// Steering toward `direction` (in the map frame: x right, −z ahead, y
    /// up) at `throttle`: horizontal travel along it, and climbing or
    /// descending with its vertical part.
    static func steering(direction: SIMD3<Float>, throttle: Float) -> ControlInput {
        var input = ControlInput()
        let d = SIMD3<Double>(direction)
        let t = Double(min(max(throttle, 0), 1))
        input.move = SIMD2(d.x, -d.z) * t
        // Climbing changes altitude exponentially; pointing up climbs.
        input.climb = d.y * t
        return input
    }

    /// The yaw of the line from `a` to `b`, radians counterclockwise from +x
    /// seen from above.
    static func yaw(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Double {
        Double(atan2(-(b.z - a.z), b.x - a.x))
    }

    /// One frame. `mapFromRoom` turns room directions into the map frame
    /// (the room placement's inverse rotation), for steering.
    mutating func update(left leftHand: HandJoints?, right rightHand: HandJoints?, deltaTime: Float,
                         mapFromRoom: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        -> (actions: [HandAction], overlay: HandOverlay) {
        left.update(leftHand)
        right.update(rightHand)
        func hand(_ c: Chirality) -> HandJoints? { c == .left ? leftHand : rightHand }
        func detector(_ c: Chirality) -> HandPoseDetector { c == .left ? left : right }

        var actions: [HandAction] = []
        var overlay = HandOverlay()

        switch scheme {
        case .none:
            break
        case .pointAndJump, .pointToFly:
            // Keep the pointing hand while it points; otherwise take
            // whichever hand points, the right first.
            if let current = pointerHand, !detector(current).isPointing { pointerHand = nil }
            if pointerHand == nil {
                pointerHand = right.isPointing ? .right : (left.isPointing ? .left : nil)
            }
            let raw = pointerHand.flatMap(hand).map { HandRay(origin: $0.index.tip, direction: $0.index.direction) }
            overlay.pointer = smoother.update(raw, deltaTime: deltaTime)
            guard let pointer = pointerHand, let ray = overlay.pointer else { break }
            let other = pointer.other
            let pinching = detector(other).isPinching
            if scheme == .pointAndJump {
                overlay.emphasis = pinching ? 1 : 0
                if pinching, wasPinching[other] != true { actions.append(.jumpToPointer) }
            } else if let otherHand = hand(other), !detector(other).isPointing {
                let throttle = Self.throttle(pinchDistance: otherHand.pinchDistance)
                // A small dead zone, so a relaxed hand doesn't creep.
                let effective = throttle < 0.1 ? 0 : (throttle - 0.1) / 0.9
                overlay.emphasis = effective
                if effective > 0 {
                    actions.append(.steer(Self.steering(direction: mapFromRoom.act(ray.direction),
                                                        throttle: effective)))
                }
            }
        case .grabWorld:
            let holding = (left: left.isFist ? leftHand?.grabPoint : nil,
                           right: right.isFist ? rightHand?.grabPoint : nil)
            let count = (holding.left == nil ? 0 : 1) + (holding.right == nil ? 0 : 1)
            // A change of which hands hold restarts the grab from here.
            if let grab, count != grab.hands || (holding.left == nil) != (grab.left == nil) {
                actions.append(.endGrab)
                self.grab = nil
            }
            if count > 0, grab == nil { grab = GrabState(left: holding.left, right: holding.right) }
            if let grab {
                if let l0 = grab.left, let r0 = grab.right, let l = holding.left, let r = holding.right {
                    let start = (l0 + r0) / 2, current = (l + r) / 2
                    let spread0 = simd_distance(SIMD2(l0.x, l0.z), SIMD2(r0.x, r0.z))
                    let spread = simd_distance(SIMD2(l.x, l.z), SIMD2(r.x, r.z))
                    let magnification = spread0 > 0.02 ? Double(spread / spread0) : 1
                    let twist = remainder(Self.yaw(from: l, to: r) - Self.yaw(from: l0, to: r0), 2 * .pi)
                    actions.append(.grab(start: start, current: current, magnification: magnification, twist: twist))
                } else if let start = grab.left ?? grab.right, let current = holding.left ?? holding.right {
                    actions.append(.grab(start: start, current: current, magnification: nil, twist: nil))
                }
            }
            overlay.grabs = [holding.left, holding.right].compactMap { $0 }
        }
        wasPinching[.left] = left.isPinching
        wasPinching[.right] = right.isPinching
        return (actions, overlay)
    }

    /// Ends anything in progress (the scheme changed, or tracking stopped).
    mutating func reset() -> [HandAction] {
        let ending: [HandAction] = grab == nil ? [] : [.endGrab]
        self = HandControlController(scheme: scheme)
        return ending
    }
}

/// Where a ray in the immersive space meets the map.
enum MapRaycast {
    /// The first point along the room-space ray at `surfaceHeight` metres
    /// above the ellipsoid, ECEF, given the room ← ECEF placement. Nil on a
    /// miss (pointing at the sky).
    static func hit(_ ray: HandRay, roomFromECEF: Similarity, surfaceHeight: Double) -> SIMD3<Double>? {
        let ecefFromRoom = roomFromECEF.inverse
        let origin = ecefFromRoom.apply(SIMD3<Double>(ray.origin))
        let direction = ecefFromRoom.rotation.act(SIMD3<Double>(ray.direction))
        guard case let .hit(point, _) = Geodesy.intersect(ray: Ray(origin: origin, direction: direction),
                                                           surfaceHeight: surfaceHeight)
        else { return nil }
        return point
    }

    /// The local up at an ECEF point, as a room direction.
    static func up(at ecef: SIMD3<Double>, roomFromECEF: Similarity) -> SIMD3<Double> {
        let (coordinate, _) = Geodesy.geodetic(ecef)
        let up = Geodesy.enu(latitude: coordinate.latitude, longitude: coordinate.longitude).up
        return simd_normalize(roomFromECEF.rotation.act(up))
    }
}

/// A smooth flight between two camera poses: along the great circle, with
/// the heading turning the shortest way, rising in the middle when the
/// distance is large next to the altitude (zoom out, travel, zoom in), and
/// easing in and out.
struct CameraFlight: Equatable {
    var from: CameraPose
    var to: CameraPose
    /// Extra height at the midpoint, metres.
    var hop: Double
    var duration: Double
    private(set) var elapsed = 0.0

    /// Where a jump to `target` lands: the camera (on the eye) straight
    /// above it, `altitude` metres above `groundHeight`, with the heading and
    /// pitch unchanged, so the world only slides and the pointed-at spot ends
    /// up under you. (Not on the map's placement point in front of you: that
    /// is metres away in the room, which can be kilometres of world, so
    /// pointing nearer than it would move you backwards.)
    static func jump(from camera: CameraPose, to target: GeoCoordinate, groundHeight: Double,
                     altitude: Double) -> CameraPose {
        CameraPose(latitude: target.latitude, longitude: target.longitude, height: groundHeight + altitude,
                   heading: camera.heading, pitch: camera.pitch)
    }

    /// `altitude` is the start's height above the ground, metres.
    init(from: CameraPose, to: CameraPose, altitude: Double) {
        self.from = from
        self.to = to
        let distance = GeoMath.distance(from: from.coordinate, to: to.coordinate)
        let altitude = max(altitude, 1)
        hop = min(max(0.3 * distance - altitude, 0), 20 * altitude)
        duration = min(1 + 0.5 * log2(1 + distance / altitude), 4)
    }

    var isFinished: Bool { elapsed >= duration }

    /// Advances and returns the pose now.
    mutating func advance(by deltaTime: Double) -> CameraPose {
        elapsed = min(elapsed + max(deltaTime, 0), duration)
        return pose(at: duration > 0 ? elapsed / duration : 1)
    }

    /// The pose at `fraction` (0...1) of the flight.
    func pose(at fraction: Double) -> CameraPose {
        let t = min(max(fraction, 0), 1)
        let e = t * t * (3 - 2 * t)
        let distance = GeoMath.distance(from: from.coordinate, to: to.coordinate)
        let bearing = GeoMath.bearing(from: from.coordinate, to: to.coordinate)
        let point = t >= 1 ? to.coordinate : GeoMath.destination(from: from.coordinate, bearing: bearing, distance: distance * e)
        let turn = remainder(to.heading - from.heading, 2 * .pi)
        return CameraPose(latitude: point.latitude, longitude: point.longitude,
                          height: from.height + (to.height - from.height) * e + hop * 4 * e * (1 - e),
                          heading: NavigationOperations.wrapped(from.heading + turn * e),
                          pitch: from.pitch + (to.pitch - from.pitch) * e)
    }
}
