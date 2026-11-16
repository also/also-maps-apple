import Foundation

/// The ground under the camera, every frame, from loaded tiles detailed
/// enough to trust: coarse tiles' lowest vertices can be kilometers below
/// the real ground. It sets speed and limits only; it never moves the view.
struct CameraGround: Equatable {
    private var height: EasedHeight

    init(_ value: Double = 0) { height = EasedHeight(value) }

    /// Meters above the ellipsoid.
    var value: Double { height.value }

    mutating func reset(to value: Double) { height.reset(to: value) }

    /// Aims at the lowest detailed tile near `camera` and eases toward it.
    mutating func update(camera: CameraPose, rendered: [TileHeightRange], deltaTime: Double) {
        let altitude = max(camera.height - value, 0)
        let detailed = rendered.filter { $0.radius <= max(2 * altitude, 500) }
        if let ground = GroundEstimates.envelope(detailed, around: camera.coordinate,
                                                 radius: max(20, 0.05 * altitude), statistic: .minimum) {
            height.aim(at: min(max(ground, -500), 9_000))
        }
        height.ease(deltaTime: deltaTime, halfLife95: 0.3)
    }
}
