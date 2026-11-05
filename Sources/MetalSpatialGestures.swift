import Spatial
import SwiftUI
import simd

/// Look-and-pinch for the Metal immersive space, from CompositorServices
/// spatial events (`LayerRenderer.onSpatialEvent`). There are no entities to
/// target, so this does by hand what `mapGestures` gets from SwiftUI's
/// entity-targeted gestures in the RealityKit space: pinch-drag pans,
/// two-handed pinch zooms and twists (PinchGestures), through the same
/// anchored-gesture calls on MapModel.
///
/// Each pinching hand is its own event, with its own id. A pinch starts on the
/// map only if its selection ray (the gaze when the pinch began) hits the
/// gesture slab, as an entity-targeted gesture would; one that misses is
/// ignored to its end. From then on the hand's pose drives it, and the ray
/// isn't followed.
@MainActor
final class MetalSpatialGestures {
    private typealias ID = SpatialEventCollection.Event.ID
    private let model: MapModel
    private var gestures = PinchGestures<ID>()
    /// Pinches that began off the map.
    private var ignored: Set<ID> = []

    init(model: MapModel) {
        self.model = model
    }

    func handle(_ events: SpatialEventCollection) {
        for event in events {
            let outputs: [PinchGestures<ID>.Output]
            if event.phase == .active {
                outputs = update(event)
            } else {
                // Ended or cancelled.
                ignored.remove(event.id)
                outputs = gestures.end(event.id)
            }
            for output in outputs { apply(output) }
        }
    }

    private func update(_ event: SpatialEventCollection.Event) -> [PinchGestures<ID>.Output] {
        // Indirect only, like the RealityKit space's gesture target.
        guard event.kind == .indirectPinch, !ignored.contains(event.id),
              let pose = event.inputDevicePose else { return [] }
        let hand = Self.lifted(SIMD3<Float>(pose.pose3D.position.vector))
        if gestures.isTracking(event.id) { return gestures.move(event.id, hand: hand) }

        // A new pinch.
        guard let ray = event.selectionRay,
              let hit = model.immersiveGestureHit(origin: Self.lifted(SIMD3<Float>(ray.origin.vector)),
                                                  direction: SIMD3<Float>(ray.direction.vector))
        else {
            ignored.insert(event.id)
            #if DEBUG
            print("[AlsoMaps] Metal gestures: pinch off the map, ray "
                  + (event.selectionRay.map { "\($0.origin) → \($0.direction)" } ?? "none"))
            #endif
            return []
        }
        #if DEBUG
        print("[AlsoMaps] Metal gestures: pinch on the map at \(hit), hand \(hand), chirality \(String(describing: event.chirality))")
        #endif
        return gestures.begin(event.id, hand: hand, hit: hit)
    }

    private func apply(_ output: PinchGestures<ID>.Output) {
        switch output {
        case let .drag(from, to): model.drag(from: from, to: to)
        case .endDrag: model.endDrag()
        case let .magnify(magnification, start): model.magnify(by: magnification, startedAt: start)
        case .endMagnify: model.endMagnify()
        case let .rotate(angle, start): model.rotate(by: simd_quatf(angle: angle, axis: [0, 1, 0]), startedAt: start)
        case .endRotate: model.endRotate()
        }
    }

    /// Spatial events are in the space's origin frame, whose head the
    /// simulator puts on the floor; lift them by the 1.6 m that
    /// MetalImmersiveRenderer lifts the eye there.
    private static func lifted(_ point: SIMD3<Float>) -> SIMD3<Float> {
        #if targetEnvironment(simulator)
        point + [0, 1.6, 0]
        #else
        point
        #endif
    }
}
