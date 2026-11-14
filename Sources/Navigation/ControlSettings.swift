import Foundation
import simd

/// How fast the keyboard, game controller and on-screen sticks fly the map,
/// and how the sticks respond: the values the control styles fly with. The
/// defaults here are the app's; `ControlSettings` holds the ones someone
/// changed.
struct ControlValues: Equatable {
    /// Radians per second.
    var turnRate = Double.pi / 3
    /// Fraction of height above ground (in orbit, of the distance to the
    /// pivot) traveled per second.
    var moveRate = 0.75
    /// e-folds of height above ground per second.
    var climbRate = 1.0
    /// e-folds of range (in orbit, of distance to the pivot) per second.
    var zoomRate = 1.0
    /// Rates are multiplied by this while boost (LB, left stick click, Shift)
    /// is held.
    var boost = 3.0
    /// Stick deflections below this fraction of full do nothing.
    var deadZone = 0.15
    /// Exponent of the stick response past the dead zone: 1 is linear,
    /// higher gives finer control near center. A full push is full speed
    /// either way.
    var responseCurve = 2.0
    /// Seconds to ramp from rest up to a full-deflection rate. 0 responds
    /// at once.
    var acceleration = 0.0
    /// Seconds to ramp from a full-deflection rate down to rest. 0 stops at
    /// once.
    var deceleration = 0.0
    /// Turn and climb share the right stick: a push within this many degrees
    /// of either axis does only that one. 0 lets a diagonal do both; 45 always
    /// keeps only the larger.
    var axisLock = 0.0

    static let `default` = ControlValues()

    // MARK: Sticks

    /// A raw stick position (length ≤ 1, longer is clamped) as a rate:
    /// radial dead zone, then the response curve.
    func stick(_ raw: SIMD2<Double>) -> SIMD2<Double> {
        let length = simd_length(raw)
        let magnitude = min(length, 1)
        guard magnitude > deadZone, deadZone < 1 else { return .zero }
        let scaled = (magnitude - deadZone) / (1 - deadZone)
        return raw / length * pow(scaled, responseCurve)
    }

    /// `value` with its smaller axis dropped when the push is within
    /// `axisLock` degrees of the larger one.
    func lockingAxes(_ value: SIMD2<Double>) -> SIMD2<Double> {
        guard axisLock > 0, value != .zero else { return value }
        let (major, minor) = (max(abs(value.x), abs(value.y)), min(abs(value.x), abs(value.y)))
        guard atan2(minor, major) <= axisLock * .pi / 180 else { return value }
        return abs(value.x) >= abs(value.y) ? SIMD2(value.x, 0) : SIMD2(0, value.y)
    }

    // MARK: Ramping

    /// One axis's rate moved toward `target` for `deltaTime`: away from zero
    /// at `acceleration`, toward it at `deceleration`, each in seconds for
    /// the full range. A reversal slows to rest, then speeds up.
    func ramp(_ current: Double, toward target: Double, deltaTime: Double) -> Double {
        var current = current
        var remaining = deltaTime
        if current * target < 0 {
            let toRest = abs(current) * deceleration
            guard toRest <= remaining else {
                return current - (current > 0 ? 1 : -1) * remaining / deceleration
            }
            current = 0
            remaining -= toRest
        }
        let time = abs(target) > abs(current) ? acceleration : deceleration
        guard time > 0 else { return target }
        let step = remaining / time
        return current + min(max(target - current, -step), step)
    }

    /// Every rate of `input` moved toward `target`; `fast` follows the
    /// target at once.
    func ramp(_ current: ControlInput, toward target: ControlInput, deltaTime: Double) -> ControlInput {
        var next = target
        next.move = SIMD2(ramp(current.move.x, toward: target.move.x, deltaTime: deltaTime),
                          ramp(current.move.y, toward: target.move.y, deltaTime: deltaTime))
        next.turn = ramp(current.turn, toward: target.turn, deltaTime: deltaTime)
        next.climb = ramp(current.climb, toward: target.climb, deltaTime: deltaTime)
        next.dolly = ramp(current.dolly, toward: target.dolly, deltaTime: deltaTime)
        next.pitch = ramp(current.pitch, toward: target.pitch, deltaTime: deltaTime)
        return next
    }
}

/// The control values someone has set in Settings, saved with the other
/// settings (`StreamingSettings.controls`). Each is nil until it's set, and
/// a nil one follows `ControlValues.default`, so changing a default reaches
/// everyone who left it alone without changing what anyone chose. Units are
/// `ControlValues`'.
struct ControlSettings: Codable, Equatable {
    var turnRate: Double?
    var moveRate: Double?
    var climbRate: Double?
    var zoomRate: Double?
    var boost: Double?
    var deadZone: Double?
    var responseCurve: Double?
    var acceleration: Double?
    var deceleration: Double?
    var axisLock: Double?

    /// Nothing set: every value is the default.
    var isDefault: Bool { self == ControlSettings() }

    /// The values to fly with: each one set, or else the default.
    var values: ControlValues {
        let d = ControlValues.default
        return ControlValues(turnRate: turnRate ?? d.turnRate,
                             moveRate: moveRate ?? d.moveRate,
                             climbRate: climbRate ?? d.climbRate,
                             zoomRate: zoomRate ?? d.zoomRate,
                             boost: boost ?? d.boost,
                             deadZone: deadZone ?? d.deadZone,
                             responseCurve: responseCurve ?? d.responseCurve,
                             acceleration: acceleration ?? d.acceleration,
                             deceleration: deceleration ?? d.deceleration,
                             axisLock: axisLock ?? d.axisLock)
    }
}
