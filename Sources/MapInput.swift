import GameController
import simd

/// Game-style map controls from a hardware keyboard and a game controller,
/// merged into one set of values.
///
/// Polled once per frame rather than event-driven, so held keys and sticks
/// give smooth, frame-rate-independent motion and nothing depends on SwiftUI
/// focus inside the volume.
struct MapInput {
    /// x: right (+) / left (−), y: forward (+) / back (−); length ≤ 1. Analog
    /// from a stick, so a light push moves slowly.
    var move = SIMD2<Double>.zero
    /// Turn right (+) / left (−), −1…1.
    var turn = 0.0
    /// Zoom in (+) / out (−), −1…1: triggers and =/−. In Fly, scales the
    /// frozen scene instead.
    var zoom = 0.0
    /// Climb (+) / descend (−), −1…1: right stick up/down and F/R. Normally
    /// that's zooming out/in (altitude is zoom); in Fly it moves vertically.
    var altitude = 0.0
    var fast = false

    /// One-shot actions; reported while the button is held, so the model
    /// fires them on the frame a button goes down.
    enum Action: Hashable { case previousPlace, nextPlace, faceNorth, toggleFly }
    var held: Set<Action> = []

    var isMoving: Bool { move != .zero || turn != 0 || zoom != 0 || altitude != 0 }

    /// Keyboard and controller together.
    static func current() -> MapInput {
        var input = keyboard()
        input.merge(gamepad())
        return input
    }

    private mutating func merge(_ other: MapInput) {
        move += other.move
        if simd_length(move) > 1 { move = simd_normalize(move) }
        turn = min(max(turn + other.turn, -1), 1)
        zoom = min(max(zoom + other.zoom, -1), 1)
        altitude = min(max(altitude + other.altitude, -1), 1)
        fast = fast || other.fast
        held.formUnion(other.held)
    }

    // MARK: Keyboard

    static let keyboardHint = "WASD / arrows move · Q E turn · R F descend/climb · = − zoom · Shift faster"

    static var isKeyboardConnected: Bool { GCKeyboard.coalesced != nil }

    /// The keys held right now, or no input if there's no keyboard.
    static func keyboard() -> MapInput {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return MapInput() }
        func held(_ codes: GCKeyCode...) -> Bool {
            codes.contains { keyboard.button(forKeyCode: $0)?.isPressed == true }
        }
        func axis(positive: Bool, negative: Bool) -> Double {
            (positive ? 1 : 0) - (negative ? 1 : 0)
        }

        var input = MapInput()
        input.move.x = axis(positive: held(.keyD, .rightArrow), negative: held(.keyA, .leftArrow))
        input.move.y = axis(positive: held(.keyW, .upArrow), negative: held(.keyS, .downArrow))
        if input.move != .zero { input.move /= simd_length(input.move) }
        input.turn = axis(positive: held(.keyE), negative: held(.keyQ))
        input.zoom = axis(positive: held(.equalSign, .keypadPlus), negative: held(.hyphen, .keypadHyphen))
        input.altitude = axis(positive: held(.keyF), negative: held(.keyR))
        input.fast = held(.leftShift, .rightShift)
        return input
    }

    // MARK: Game controller

    static let controllerHint = "Left stick move · Right stick turn, climb/descend · RT LT zoom · LB faster · D-pad places · Y north · X fly"

    /// The controller in use, if any (the most recently used one, or else
    /// the first connected).
    static var controller: GCController? {
        GCController.current ?? GCController.controllers().first { $0.extendedGamepad != nil }
    }

    /// Sticks, triggers and buttons right now, or no input if there's no
    /// controller. Laid out for an Xbox-style extended gamepad.
    static func gamepad() -> MapInput {
        guard let pad = controller?.extendedGamepad else { return MapInput() }
        var input = MapInput()
        input.move = stick(pad.leftThumbstick)
        let right = stick(pad.rightThumbstick)
        input.turn = right.x
        // Right stick up climbs, down descends, as on a drone.
        input.altitude = right.y
        input.zoom = trigger(pad.rightTrigger) - trigger(pad.leftTrigger)
        input.fast = pad.leftShoulder.isPressed || pad.leftThumbstickButton?.isPressed == true
        if pad.dpad.left.isPressed { input.held.insert(.previousPlace) }
        if pad.dpad.right.isPressed { input.held.insert(.nextPlace) }
        if pad.buttonY.isPressed { input.held.insert(.faceNorth) }
        if pad.buttonX.isPressed { input.held.insert(.toggleFly) }
        return input
    }

    /// Radial dead zone, then a squared response so small deflections give
    /// fine control and a full push still reaches full speed.
    private static func stick(_ pad: GCControllerDirectionPad) -> SIMD2<Double> {
        let raw = SIMD2(Double(pad.xAxis.value), Double(pad.yAxis.value))
        let deadZone = 0.15
        let magnitude = min(simd_length(raw), 1)
        guard magnitude > deadZone else { return .zero }
        let scaled = (magnitude - deadZone) / (1 - deadZone)
        return raw / simd_length(raw) * scaled * scaled
    }

    private static func trigger(_ button: GCControllerButtonInput) -> Double {
        let value = Double(button.value)
        return value < 0.05 ? 0 : value
    }
}
