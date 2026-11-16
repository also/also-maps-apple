import Foundation
import simd

/// Smooths a tracked hand's position: a One Euro filter (Casiez, Roussel and
/// Vogel, CHI 2012). It's a low-pass filter whose cutoff rises with the
/// hand's speed, so a still or slowly moving hand loses its tracking jitter
/// while a quick movement follows with little lag.
///
/// For raw hand poses, such as the Metal space's spatial events, which
/// SwiftUI's gestures would otherwise have smoothed.
struct HandFilter {
    /// Cutoff for a still hand, hertz: lower is smoother and laggier.
    var minimumCutoff = 1.5
    /// How much the cutoff rises per metre a second of speed.
    var speedCoefficient = 4.0
    /// Cutoff for the speed estimate itself, hertz.
    var speedCutoff = 1.0

    private var last: (time: TimeInterval, position: SIMD3<Double>, velocity: SIMD3<Double>)?

    init() {}

    /// The smoothed position for a sample at `time` (seconds, increasing).
    mutating func filter(_ position: SIMD3<Double>, at time: TimeInterval) -> SIMD3<Double> {
        guard let last, time > last.time else {
            if last == nil { last = (time, position, .zero) }
            return last!.position
        }
        let dt = time - last.time
        let rawVelocity = (position - last.position) / dt
        let velocity = mix(last.velocity, rawVelocity, Self.alpha(cutoff: speedCutoff, dt: dt))
        let cutoff = minimumCutoff + speedCoefficient * simd_length(velocity)
        let smoothed = mix(last.position, position, Self.alpha(cutoff: cutoff, dt: dt))
        self.last = (time, smoothed, velocity)
        return smoothed
    }

    /// The exponential smoothing weight for a cutoff and time step.
    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    private func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }
}
