import SwiftUI

/// A titled slider with its value and an optional hint under it, for
/// Settings and the debug panel.
struct SettingSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: format(value))
            Slider(value: $value, in: range, step: step)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The control speed and stick response sliders: Settings' Controls page
/// (with hints) and the volume's debug panel (without), so they can be
/// changed while flying.
struct ControlSettingsRows: View {
    @Binding var controls: ControlSettings
    var showsHints = true

    var body: some View {
        multiple("Turn speed", $controls.turnSpeed, hint: "Turning with Q E, the right stick or the turn stick.")
        multiple("Move speed", $controls.moveSpeed, hint: "Moving with WASD, the arrows or the left stick.")
        multiple("Climb speed", $controls.climbSpeed, hint: "Climbing and descending with R F or the right stick.")
        multiple("Zoom speed", $controls.zoomSpeed, hint: "Zooming with = − or the triggers.")
        slider("Boost", $controls.boost, in: 1...6, step: 0.5,
               format: { String(format: "%.1f×", $0) },
               hint: "Speed while LB, the left stick button or Shift is held.")
        slider("Stick dead zone", $controls.deadZone, in: 0...0.4, step: 0.01,
               format: { "\(Int(($0 * 100).rounded()))%" },
               hint: "How far a stick moves before anything happens.")
        slider("Stick response", $controls.responseCurve, in: 1...4, step: 0.1,
               format: { $0 == 1 ? "Linear" : String(format: "Power %.1f", $0) },
               hint: "Higher gives finer control near center; a full push is full speed either way.")
        slider("Acceleration", $controls.acceleration, in: 0...2, step: 0.05,
               format: seconds, hint: "Time to reach full speed. Instant responds right away.")
        slider("Deceleration", $controls.deceleration, in: 0...2, step: 0.05,
               format: seconds, hint: "Time to come to a stop after letting go.")
        slider("Turn and climb lock", $controls.axisLock, in: 0...45, step: 5,
               format: { $0 == 0 ? "Off" : "\(Int($0))°" },
               hint: "The right stick both turns and climbs. Within this angle of either direction, it does only that one.")
    }

    private func multiple(_ title: String, _ value: Binding<Double>, hint: String) -> some View {
        slider(title, value, in: 0.25...2, step: 0.05, format: { String(format: "%.2f×", $0) }, hint: hint)
    }

    private func slider(_ title: String, _ value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String, hint: String) -> some View {
        SettingSlider(title: title, value: value, range: range, step: step, format: format,
                      hint: showsHints ? hint : nil)
    }

    private func seconds(_ value: Double) -> String {
        value == 0 ? "Instant" : String(format: "%.2f s", value)
    }
}
