import SwiftUI
import simd

/// An on-screen thumbstick: drag the knob anywhere in the base; it springs
/// back to the centre on release. Reports x right (+) and y up (+), length
/// ≤ 1, with a dead zone and a squared response like a game controller's
/// stick, so a light push moves slowly.
struct Joystick: View {
    var label: String
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
                    onChange(Self.response(SIMD2(d.x, -d.y) / reach))
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.2)) { offset = .zero }
                    onChange(.zero)
                }
        )
        .accessibilityLabel(label)
    }

    /// Radial dead zone, then squared.
    static func response(_ raw: SIMD2<Double>) -> SIMD2<Double> {
        let deadZone = 0.12
        let magnitude = min(simd_length(raw), 1)
        guard magnitude > deadZone else { return .zero }
        let scaled = (magnitude - deadZone) / (1 - deadZone)
        return raw / simd_length(raw) * scaled * scaled
    }
}

/// Drone-style ("mode 2") sticks over the map: the left stick climbs and
/// turns, the right one moves forward, back and sideways. A slider on the
/// right edge tilts the view up and down.
struct DroneControls: View {
    let map: ScreenMap

    var body: some View {
        HStack(alignment: .bottom) {
            Joystick(label: "climb · turn") { value in
                map.touchInput.altitude = value.y
                map.touchInput.turn = value.x
            }
            Spacer()
            TiltControl { map.touchInput.pitch = $0 }
            Joystick(label: "move") { value in
                map.touchInput.move = value
            }
        }
        .padding(.horizontal, 20)
    }
}

/// A vertical spring-loaded slider: push up to look up, down to look down.
struct TiltControl: View {
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
                    onChange(Joystick.response(SIMD2(0, raw)).y)
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.2)) { offset = 0 }
                    onChange(0)
                }
        )
        .accessibilityLabel("Look up or down")
    }
}
