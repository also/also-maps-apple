import ARKit
import QuartzCore

/// Reads where the headset is in the immersive space, through ARKit world
/// tracking. Only immersive spaces get the device's pose; the simulator and
/// the Shared Space don't.
@MainActor
final class HeadTracker {
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    /// Starts world tracking and returns the headset's position in the
    /// immersive space (metres, the origin on the floor where the space
    /// opened) once it's tracked, or nil if tracking isn't available or
    /// doesn't settle within `timeout`.
    func headPosition(timeout: Duration = .seconds(3)) async -> SIMD3<Float>? {
        guard WorldTrackingProvider.isSupported else { return nil }
        do {
            try await session.run([worldTracking])
        } catch {
            #if DEBUG
            print("[AlsoMaps] world tracking failed: \(error.localizedDescription)")
            #endif
            return nil
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked {
                let position = anchor.originFromAnchorTransform.columns.3
                return SIMD3(position.x, position.y, position.z)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Runs world tracking and calls `update` with the headset's pose in
    /// the immersive space (originFromAnchorTransform) every `interval`
    /// while it's tracked, until the task is cancelled; then stops. Use a
    /// fresh tracker for this, not one that's been stopped.
    func follow(every interval: Duration = .milliseconds(50), _ update: (simd_float4x4) -> Void) async {
        guard WorldTrackingProvider.isSupported else { return }
        do {
            try await session.run([worldTracking])
        } catch {
            #if DEBUG
            print("[AlsoMaps] world tracking failed: \(error.localizedDescription)")
            #endif
            return
        }
        while !Task.isCancelled {
            if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked {
                update(anchor.originFromAnchorTransform)
            }
            try? await Task.sleep(for: interval)
        }
        session.stop()
    }

    func stop() {
        session.stop()
    }
}
