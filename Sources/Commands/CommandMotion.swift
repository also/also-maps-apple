import Foundation

/// A commanded change of view, eased over `duration` so it reads as flying
/// rather than a jump: the same climb, turn, move and pitch operations the
/// controls use, in a fixed total amount. The map steps it each frame.
struct CommandMotion: Equatable, Sendable {
    var climb = 0.0
    /// Radians, clockwise seen from above.
    var turn = 0.0
    var forward = 0.0
    var right = 0.0
    /// Radians, up positive.
    var pitch = 0.0
    var duration = 1.2
    private(set) var elapsed = 0.0

    var isFinished: Bool { elapsed >= duration }

    /// The motion for a command that changes the view in place, from the
    /// camera and its height above the ground now; nil for `goTo`.
    init?(_ command: MapCommand, camera: CameraPose, altitude: Double) {
        switch command {
        case .goTo:
            return nil
        case let .climb(meters):
            climb = meters
        case let .setAltitude(meters):
            climb = meters - altitude
        case let .turn(degrees):
            turn = degrees * .pi / 180
        case let .face(heading):
            turn = NavigationOperations.wrapped(heading * .pi / 180 - camera.heading)
        case let .move(forwardMeters, rightMeters):
            forward = forwardMeters
            right = rightMeters
        case let .pitch(degrees):
            pitch = degrees * .pi / 180
        }
    }

    init(climb: Double = 0, turn: Double = 0, forward: Double = 0, right: Double = 0, pitch: Double = 0,
         duration: Double = 1.2) {
        self.climb = climb
        self.turn = turn
        self.forward = forward
        self.right = right
        self.pitch = pitch
        self.duration = duration
    }

    /// Advances by `deltaTime`, applying this frame's share of the motion.
    mutating func step(_ state: NavigationState, deltaTime: Double, context: NavigationContext) -> NavigationState {
        guard !isFinished else { return state }
        let before = Self.ease(elapsed / duration)
        elapsed = min(elapsed + max(deltaTime, 0), duration)
        let share = Self.ease(elapsed / duration) - before
        var state = state
        if climb != 0 { state = NavigationOperations.climb(state, by: climb * share, context: context) }
        if turn != 0 { state = NavigationOperations.turn(state, by: turn * share) }
        if pitch != 0 { state = NavigationOperations.pitch(state, by: pitch * share) }
        if forward != 0 || right != 0 {
            state = NavigationOperations.move(state, forward: forward * share, right: right * share)
        }
        return state
    }

    /// Smoothstep: starts and ends gently, and reaches 1 exactly.
    private static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
