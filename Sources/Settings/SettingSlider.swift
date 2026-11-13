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
/// changed while flying. A slider shows the default until it's moved; then
/// its value is saved (`ControlSettings`).
struct ControlSettingsRows: View {
    @Binding var controls: ControlSettings
    var showsHints = true

    var body: some View {
        slider("Turn speed", \.turnRate, \.turnRate, in: 15...120, step: 5, scale: 180 / .pi,
               format: { "\(Int($0.rounded()))°/s" },
               hint: "Turning with Q E, the right stick or the turn stick.")
        slider("Move speed", \.moveRate, \.moveRate, in: 0.2...1.5, step: 0.05,
               format: { "\(Int(($0 * 100).rounded()))% of height/s" },
               hint: "Moving with WASD, the arrows or the left stick, as a share of your height above the ground each second.")
        slider("Climb speed", \.climbRate, \.climbRate, in: 0.25...2, step: 0.05, format: perSecond,
               hint: "Climbing and descending with R F or the right stick: how much your height multiplies by each second.")
        slider("Zoom speed", \.zoomRate, \.zoomRate, in: 0.25...2, step: 0.05, format: perSecond,
               hint: "Zooming with = − or the triggers: how much the distance multiplies by each second.")
        slider("Boost", \.boost, \.boost, in: 1...6, step: 0.5,
               format: { String(format: "%.1f×", $0) },
               hint: "Speed while LB, the left stick button or Shift is held.")
        slider("Stick dead zone", \.deadZone, \.deadZone, in: 0...0.4, step: 0.01,
               format: { "\(Int(($0 * 100).rounded()))%" },
               hint: "How far a stick moves before anything happens.")
        slider("Stick response", \.responseCurve, \.responseCurve, in: 1...4, step: 0.1,
               format: { $0 == 1 ? "Linear" : String(format: "Power %.1f", $0) },
               hint: "Higher gives finer control near center; a full push is full speed either way.")
        slider("Acceleration", \.acceleration, \.acceleration, in: 0...2, step: 0.05, format: seconds,
               hint: "Time to reach full speed. Instant responds right away.")
        slider("Deceleration", \.deceleration, \.deceleration, in: 0...2, step: 0.05, format: seconds,
               hint: "Time to come to a stop after letting go.")
        slider("Turn and climb lock", \.axisLock, \.axisLock, in: 0...45, step: 5,
               format: { $0 == 0 ? "Off" : "\(Int($0))°" },
               hint: "The right stick both turns and climbs. Within this angle of either direction, it does only that one.")
    }

    /// A slider over `setting`, showing `fallback`'s default until it's
    /// moved, in units of the stored value times `scale`.
    private func slider(_ title: String,
                        _ setting: WritableKeyPath<ControlSettings, Double?>,
                        _ fallback: KeyPath<ControlValues, Double>,
                        in range: ClosedRange<Double>, step: Double, scale: Double = 1,
                        format: @escaping (Double) -> String, hint: String) -> some View {
        let value = Binding<Double>(
            get: { (controls[keyPath: setting] ?? ControlValues.default[keyPath: fallback]) * scale },
            set: { controls[keyPath: setting] = $0 / scale })
        return SettingSlider(title: title, value: value, range: range, step: step, format: format,
                             hint: showsHints ? hint : nil)
    }

    private func perSecond(_ rate: Double) -> String {
        String(format: "×%.2f/s", exp(rate))
    }

    private func seconds(_ value: Double) -> String {
        value == 0 ? "Instant" : String(format: "%.2f s", value)
    }
}
