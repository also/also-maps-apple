import SwiftUI
import simd

/// An on-screen thumbstick: drag the knob anywhere in the base; it springs
/// back to the center on release. Reports x right (+) and y up (+), length
/// ≤ 1, with the same dead zone and response curve as a game controller's
/// stick (`ControlSettings.stick`), so a light push moves slowly.
struct Joystick: View {
    var label: String
    var controls = ControlSettings.default
    /// Drops the smaller axis near either one, per `ControlSettings.axisLock`.
    var locksAxes = false
    var onChange: (SIMD2<Double>) -> Void
    var diameter: CGFloat = 132
    @State private var offset: CGSize = .zero

    private var radius: CGFloat { diameter / 2 }
    private var knob: CGFloat { diameter * 0.42 }

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.25))
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1.5))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .offset(y: -radius + 12)
            Circle()
                .fill(.white.opacity(0.75))
                .frame(width: knob, height: knob)
                .shadow(radius: 2)
                .offset(offset)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var d = SIMD2(Double(value.location.x - radius), Double(value.location.y - radius))
                    let reach = Double(radius - knob / 2)
                    if simd_length(d) > reach { d = d / simd_length(d) * reach }
                    offset = CGSize(width: d.x, height: d.y)
                    let value = controls.stick(SIMD2(d.x, -d.y) / reach)
                    onChange(locksAxes ? controls.lockingAxes(value) : value)
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.2)) { offset = .zero }
                    onChange(.zero)
                }
        )
        .accessibilityLabel(label)
    }
}

/// Sticks over the map laid out like the game controller's (MapInput):
/// the left stick moves forward, back and sideways, the right one turns
/// and climbs. A slider between them tilts the view up and down.
struct DroneControls: View {
    let map: ScreenMap

    var body: some View {
        HStack(alignment: .bottom) {
            Joystick(label: "move", controls: map.settings.controls) { value in
                map.touchInput.move = value
            }
            Spacer()
            TiltControl(controls: map.settings.controls) { map.touchInput.pitch = $0 }
            Joystick(label: "turn · climb", controls: map.settings.controls, locksAxes: true) { value in
                map.touchInput.turn = value.x
                map.touchInput.altitude = value.y
            }
        }
        .padding(.horizontal, 20)
    }
}

/// A vertical spring-loaded slider: push up to look up, down to look down.
struct TiltControl: View {
    var controls = ControlSettings.default
    var onChange: (Double) -> Void
    var height: CGFloat = 132
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.25))
                .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1.5))
            Image(systemName: "arrow.up.and.down")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Circle()
                .fill(.white.opacity(0.75))
                .frame(width: 30, height: 30)
                .offset(y: offset)
        }
        .frame(width: 40, height: height)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let reach = height / 2 - 15
                    offset = min(max(value.location.y - height / 2, -reach), reach)
                    let raw = Double(-offset / reach)
                    onChange(controls.stick(SIMD2(0, raw)).y)
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.2)) { offset = 0 }
                    onChange(0)
                }
        )
        .accessibilityLabel("Look up or down")
    }
}
