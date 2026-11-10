#if os(visionOS)
import ARKit
import Foundation
import simd

/// The hand-tracked control schemes in the Metal immersive space
/// (Settings › Immersion › Hand controls): reads ARKit's hands, runs
/// HandControlController on them and applies what it asks for to the
/// MapModel, then builds the overlay MetalHandOverlay draws.
@MainActor
final class MetalHandControls {
    private let model: MapModel
    /// Its own session, started only when a scheme needs hands, so world
    /// tracking (the renderer's session) is unaffected either way.
    private let session = ARKitSession()
    private var provider: HandTrackingProvider?
    private var starting = false
    private var controller = HandControlController(scheme: .none)
    private var steered = false
    private(set) var overlay = HandOverlay()

    /// Where the pointer meets the map, and the surface height it was cast
    /// against.
    private(set) var hit: (ecef: SIMD3<Double>, room: SIMD3<Float>, up: SIMD3<Float>)?
    /// The terrain at the pointer, from the bridge's height sampler; until
    /// the first sample, the ground the map is placed on.
    private var pointerSurface: Double?
    private var lastSample = Date.distantPast
    private var sampleGeneration = 0

    init(model: MapModel) {
        self.model = model
    }

    /// One frame, before the model's tick: hands predicted for `time`
    /// (the frame's presentation, seconds on the layer clock).
    func update(time: TimeInterval, deltaTime: Float) {
        let scheme = HandControlScheme.current
        if scheme != controller.scheme {
            apply(controller.reset())
            controller = HandControlController(scheme: scheme)
            overlay = HandOverlay()
            hit = nil
        }
        guard scheme.usesHands else { return }
        guard let provider, provider.state == .running else {
            startTracking()
            return
        }
        let hands = provider.handAnchors(at: time)
        let (actions, overlay) = controller.update(left: hands.leftHand.flatMap(Self.skeleton),
                                                   right: hands.rightHand.flatMap(Self.skeleton),
                                                   deltaTime: deltaTime, mapFromRoom: model.mapFromRoom)
        self.overlay = overlay
        apply(actions, deltaTime: Double(deltaTime))
    }

    /// After the model's tick, with this frame's placement: where the
    /// pointer meets the map.
    func castPointer() {
        guard let pointer = overlay.pointer, let placement = model.immersivePlacement else {
            hit = nil
            pointerSurface = nil
            return
        }
        let surface = pointerSurface ?? placement.groundHeight
        guard let ecef = MapRaycast.hit(pointer, roomFromECEF: placement.roomFromECEF, surfaceHeight: surface) else {
            hit = nil
            return
        }
        let room = SIMD3<Float>(placement.roomFromECEF.apply(ecef))
        let up = SIMD3<Float>(MapRaycast.up(at: ecef, roomFromECEF: placement.roomFromECEF))
        hit = (ecef, room, up)
        refineSurface(at: ecef, roomDistance: simd_distance(pointer.origin, room), scale: placement.roomFromECEF.scale)
    }

    /// The overlay as lines in the immersive space.
    var segments: [MetalHandOverlay.Segment] {
        var segments: [MetalHandOverlay.Segment] = []
        if let pointer = overlay.pointer {
            let emphasis = overlay.emphasis
            let colour = SIMD4<Float>(0.6 + 0.4 * emphasis, 0.9, 1 - 0.7 * emphasis, 0.85)
            let length = hit.map { simd_distance(pointer.origin, $0.room) } ?? 30
            // In pieces that widen with distance, so the far end stays visible.
            let pieces = 12
            for i in 0..<pieces {
                let d0 = length * Float(i) / Float(pieces), d1 = length * Float(i + 1) / Float(pieces)
                segments.append(.init(a: pointer.point(at: d0), b: pointer.point(at: d1), colour: colour,
                                      width: 0.003 + 0.003 * (d0 + d1) / 2))
            }
            if let hit {
                let radius = max(0.04, 0.025 * length)
                segments += MetalHandOverlay.ring(centre: hit.room + hit.up * 0.01, up: hit.up, radius: radius,
                                                  colour: colour, width: radius * 0.15)
                segments += MetalHandOverlay.ring(centre: hit.room + hit.up * 0.01, up: hit.up, radius: radius * 0.35,
                                                  colour: colour, width: radius * 0.12)
            }
        }
        for grab in overlay.grabs {
            segments += MetalHandOverlay.cross(centre: grab, size: 0.025, colour: [1, 0.8, 0.3, 0.9], width: 0.004)
        }
        return segments
    }

    func stop() {
        apply(controller.reset())
        session.stop()
    }

    // MARK: Private

    private func startTracking() {
        guard !starting, HandTrackingProvider.isSupported else { return }
        starting = true
        Task {
            let authorization = await session.requestAuthorization(for: [.handTracking])
            guard authorization[.handTracking] == .allowed else {
                print("[AlsoMaps] hand tracking not allowed; hand controls are off")
                return
            }
            let provider = HandTrackingProvider()
            do {
                try await session.run([provider])
                self.provider = provider
            } catch {
                print("[AlsoMaps] hand tracking didn't start: \(error)")
            }
            starting = false
        }
    }

    private func apply(_ actions: [HandAction], deltaTime: Double = 0) {
        var steeredNow = false
        for action in actions {
            switch action {
            case .jumpToPointer:
                guard let hit else { break }
                let (_, height) = Geodesy.geodetic(hit.ecef)
                model.fly(toGround: hit.ecef, groundHeight: height)
            case let .grab(start, current, magnification, twist):
                model.drag(from: start, to: current)
                if let magnification { model.magnify(by: magnification, startedAt: start) }
                if let twist { model.rotate(by: simd_quatf(angle: Float(twist), axis: [0, 1, 0]), startedAt: start) }
            case .endGrab:
                model.endDrag()
                model.endMagnify()
                model.endRotate()
            case let .steer(input):
                model.steerByHand(input, deltaTime: deltaTime)
                steeredNow = true
            }
        }
        if steered, !steeredNow { model.endHandSteering() }
        steered = steeredNow
    }

    /// A few times a second while pointing: the terrain height near the hit,
    /// so the ray stops on hills rather than on the placed ground's level.
    private func refineSurface(at ecef: SIMD3<Double>, roomDistance: Float, scale: Double) {
        guard Date().timeIntervalSince(lastSample) > 0.25 else { return }
        lastSample = Date()
        sampleGeneration += 1
        let generation = sampleGeneration
        let (coordinate, _) = Geodesy.geodetic(ecef)
        // About a hand's width at the hit, in world metres.
        let radius = max(Double(roomDistance) * 0.02 / scale, 1)
        model.streaming.sampleGroundHeight(around: coordinate, radius: radius) { [weak self] height in
            MainActor.assumeIsolated {
                guard let self, generation == self.sampleGeneration, height.isFinite,
                      self.overlay.pointer != nil else { return }
                self.pointerSurface = min(max(height, -500), 9_000)
            }
        }
    }

    private static func skeleton(_ anchor: HandAnchor) -> HandJoints? {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        let origin = anchor.originFromAnchorTransform
        func point(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let joint = skeleton.joint(name)
            let p = (origin * joint.anchorFromJointTransform).columns.3
            return SIMD3(p.x, p.y, p.z)
        }
        func finger(_ knuckle: HandSkeleton.JointName, _ base: HandSkeleton.JointName,
                    _ intermediate: HandSkeleton.JointName, _ tip: HandSkeleton.JointName) -> HandJoints.Finger {
            .init(knuckle: point(knuckle), intermediateBase: point(base),
                  intermediateTip: point(intermediate), tip: point(tip))
        }
        return HandJoints(
            wrist: point(.wrist), thumbTip: point(.thumbTip),
            index: finger(.indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip),
            middle: finger(.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip),
            ring: finger(.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip),
            little: finger(.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip))
    }
}
#endif
