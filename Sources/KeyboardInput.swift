import GameController
import simd

/// Game-style map controls read from a connected hardware keyboard.
///
/// Polled once per frame rather than event-driven, so held keys give smooth,
/// frame-rate-independent motion and nothing depends on SwiftUI keyboard focus
/// inside the volume.
struct KeyboardInput {
    /// x: right (+) / left (−), y: forward (+) / back (−), each −1…1.
    var move = SIMD2<Double>.zero
    /// Turn right (+) / left (−).
    var turn = 0.0
    /// Zoom in (+) / out (−).
    var zoom = 0.0
    var fast = false

    var isActive: Bool { move != .zero || turn != 0 || zoom != 0 }

    static let hint = "WASD / arrows move · Q E turn · R F zoom · Shift faster"

    static var isKeyboardConnected: Bool { GCKeyboard.coalesced != nil }

    /// The keys held right now, or no input if there's no keyboard.
    static func current() -> KeyboardInput {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return KeyboardInput() }
        func held(_ codes: GCKeyCode...) -> Bool {
            codes.contains { keyboard.button(forKeyCode: $0)?.isPressed == true }
        }
        func axis(positive: Bool, negative: Bool) -> Double {
            (positive ? 1 : 0) - (negative ? 1 : 0)
        }

        var input = KeyboardInput()
        input.move.x = axis(positive: held(.keyD, .rightArrow), negative: held(.keyA, .leftArrow))
        input.move.y = axis(positive: held(.keyW, .upArrow), negative: held(.keyS, .downArrow))
        if input.move != .zero { input.move /= simd_length(input.move) }
        input.turn = axis(positive: held(.keyE), negative: held(.keyQ))
        input.zoom = axis(positive: held(.keyR, .equalSign, .keypadPlus),
                          negative: held(.keyF, .hyphen, .keypadHyphen))
        input.fast = held(.leftShift, .rightShift)
        return input
    }
}
