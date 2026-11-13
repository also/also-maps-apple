import Foundation
import simd

/// How fast the keyboard, game controller and on-screen sticks fly the map,
/// and how the sticks respond. Speeds are multiples of the control styles'
/// built-in rates, so 1 is how the app shipped. Saved with the other
/// settings (`StreamingSettings.controls`), so Reset to Defaults covers them.
struct ControlSettings: Codable, Equatable {
    /// Multiple of the turn (and orbit) rate.
    var turnSpeed = 1.0
    /// Multiple of the move (and pan) rate.
    var moveSpeed = 1.0
    /// Multiple of the climb rate.
    var climbSpeed = 1.0
    /// Multiple of the zoom rate.
    var zoomSpeed = 1.0
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

    static let `default` = ControlSettings()

    init() {}

    /// Missing keys keep their defaults, as in `StreamingSettings`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ControlSettings()
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try c.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        turnSpeed = try value(.turnSpeed, d.turnSpeed)
        moveSpeed = try value(.moveSpeed, d.moveSpeed)
        climbSpeed = try value(.climbSpeed, d.climbSpeed)
        zoomSpeed = try value(.zoomSpeed, d.zoomSpeed)
        boost = try value(.boost, d.boost)
        deadZone = try value(.deadZone, d.deadZone)
        responseCurve = try value(.responseCurve, d.responseCurve)
        acceleration = try value(.acceleration, d.acceleration)
        deceleration = try value(.deceleration, d.deceleration)
        axisLock = try value(.axisLock, d.axisLock)
    }

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
