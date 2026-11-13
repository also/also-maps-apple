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
    /// Zoom in (+) / out (−), −1…1: triggers and =/−.
    var zoom = 0.0
    /// Climb (+) / descend (−), −1…1: right stick up/down and F/R. Normally
    /// that's zooming out/in (altitude is zoom).
    var altitude = 0.0
    /// Look up (+) / down (−), −1…1: T/G. Flat screens only; the visionOS
    /// hosts set pitch themselves.
    var pitch = 0.0
    var fast = false

    /// One-shot actions; reported while the button is held, so the model
    /// fires them on the frame a button goes down.
    enum Action: Hashable { case faceNorth }
    var held: Set<Action> = []

    /// The same values as rates for the control styles.
    var controlInput: ControlInput {
        ControlInput(move: move, turn: turn, climb: altitude, dolly: zoom, pitch: pitch, fast: fast)
    }

    /// Keyboard and controller together, with the controller's sticks
    /// shaped by `controls`.
    static func current(controls: ControlValues) -> MapInput {
        var input = keyboard()
        input.merge(gamepad(controls: controls))
        return input
    }

    /// Adds `other` in, keeping each value in range.
    mutating func merge(_ other: MapInput) {
        move += other.move
        if simd_length(move) > 1 { move = simd_normalize(move) }
        turn = min(max(turn + other.turn, -1), 1)
        zoom = min(max(zoom + other.zoom, -1), 1)
        altitude = min(max(altitude + other.altitude, -1), 1)
        pitch = min(max(pitch + other.pitch, -1), 1)
        fast = fast || other.fast
        held.formUnion(other.held)
    }

    // MARK: Keyboard

    static let keyboardHint = "WASD / arrows move · Q E turn · R F descend/climb · = − zoom · Shift faster"
    /// For flat screens, where you look up and down with the keyboard.
    static let screenKeyboardHint = "WASD / arrows move · Q E turn · T G look up/down · R F descend/climb · = − zoom · Shift faster"

    /// For the Mac's mouse and trackpad, which aren't read here (PointerSurface).
    static let pointerHint = "Drag or scroll pan · Pinch or ⌥ scroll zoom · Right-drag turn, tilt · ⇧ scroll tilt · Double-click zoom in, ⌥ out"

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
        input.pitch = axis(positive: held(.keyT), negative: held(.keyG))
        input.fast = held(.leftShift, .rightShift)
        return input
    }

    // MARK: Game controller

    static let controllerHint = "Left stick move · Right stick turn, climb/descend · RT LT zoom · LB faster · Y north"

    /// The controller in use, if any (the most recently used one, or else
    /// the first connected).
    static var controller: GCController? {
        GCController.current ?? GCController.controllers().first { $0.extendedGamepad != nil }
    }

    /// Sticks, triggers and buttons right now, or no input if there's no
    /// controller. Laid out for an Xbox-style extended gamepad.
    static func gamepad(controls: ControlValues) -> MapInput {
        guard let pad = controller?.extendedGamepad else { return MapInput() }
        var input = MapInput()
        input.move = controls.stick(stick(pad.leftThumbstick))
        let right = controls.lockingAxes(controls.stick(stick(pad.rightThumbstick)))
        input.turn = right.x
        // Right stick up climbs, down descends, as on a drone.
        input.altitude = right.y
        input.zoom = trigger(pad.rightTrigger) - trigger(pad.leftTrigger)
        input.fast = pad.leftShoulder.isPressed || pad.leftThumbstickButton?.isPressed == true
        if pad.buttonY.isPressed { input.held.insert(.faceNorth) }
        return input
    }

    /// The stick's raw position; `ControlValues.stick` shapes it.
    private static func stick(_ pad: GCControllerDirectionPad) -> SIMD2<Double> {
        SIMD2(Double(pad.xAxis.value), Double(pad.yAxis.value))
    }

    private static func trigger(_ button: GCControllerButtonInput) -> Double {
        let value = Double(button.value)
        return value < 0.05 ? 0 : value
    }
}
