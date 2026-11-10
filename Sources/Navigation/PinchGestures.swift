import simd

/// Turns raw pinches (each hand's position over time, and where its pinch
/// began on the map) into the map's gestures, for hosts that get raw input
/// instead of SwiftUI's entity-targeted gestures: the visionOS Metal space's
/// spatial events. The output matches what `mapGestures` feeds MapModel in
/// the RealityKit space:
///
/// - one hand pinches and moves: drag, the point it pinched following the
///   hand;
/// - two hands: magnify by the change in the horizontal distance between
///   them, and twist by the turn of the line between them about +Y, around
///   the point between where their pinches began.
///
/// Positions are host-space metres (y up). Going from two hands to one drags
/// with the hand left, from where its point is now, so nothing jumps.
struct PinchGestures<ID: Hashable> {
    enum Output: Equatable {
        case drag(from: SIMD3<Float>, to: SIMD3<Float>)
        case endDrag
        /// Relative to the gesture's start, as MagnifyGesture's.
        case magnify(by: Double, startedAt: SIMD3<Float>)
        case endMagnify
        /// Counterclockwise about +Y seen from above, radians since the
        /// gesture's start, as RotateGesture3D's rotation measures it.
        case rotate(angle: Float, startedAt: SIMD3<Float>)
        case endRotate
    }

    /// A drag begins once the hand has moved this far, like DragGesture's
    /// minimum distance, so a pinch that's about to become two-handed, or a
    /// still one, doesn't pan.
    var dragThreshold: Float = 0.01

    private struct Touch {
        /// Where the pinch met the map.
        var hit: SIMD3<Float>
        var handStart: SIMD3<Float>
        var hand: SIMD3<Float>
        var moved = false
        /// Was part of a two-handed gesture, so a drag after it starts from
        /// where its point is now, not where it began.
        var paired = false
        /// The pinched point carried with the hand.
        var location: SIMD3<Float> { hit + hand - handStart }
    }
    private var touches: [ID: Touch] = [:]
    /// In the order they began.
    private var order: [ID] = []
    private var pair: (a: ID, b: ID, distance: Float, angle: Float, start: SIMD3<Float>)?
    private var drag: (id: ID, start: SIMD3<Float>, handStart: SIMD3<Float>)?

    init() {}

    /// Whether `id` is a pinch in progress that began on the map.
    func isTracking(_ id: ID) -> Bool { touches[id] != nil }

    /// A pinch began on the map at `hit`, with the hand at `hand`.
    mutating func begin(_ id: ID, hand: SIMD3<Float>, hit: SIMD3<Float>) -> [Output] {
        if touches[id] != nil { return move(id, hand: hand) }
        touches[id] = Touch(hit: hit, handStart: hand, hand: hand)
        order.append(id)
        return outputs()
    }

    /// The hand of a pinch in progress moved. Unknown ids (pinches that
    /// didn't begin on the map) are ignored.
    mutating func move(_ id: ID, hand: SIMD3<Float>) -> [Output] {
        guard var touch = touches[id] else { return [] }
        touch.hand = hand
        if simd_distance(hand, touch.handStart) > dragThreshold { touch.moved = true }
        touches[id] = touch
        return outputs()
    }

    /// A pinch ended or was cancelled.
    mutating func end(_ id: ID) -> [Output] {
        guard touches.removeValue(forKey: id) != nil else { return [] }
        order.removeAll { $0 == id }
        var result: [Output] = []
        if let pair, pair.a == id || pair.b == id {
            self.pair = nil
            result += [.endMagnify, .endRotate]
        }
        if drag?.id == id {
            drag = nil
            result.append(.endDrag)
        }
        return result + outputs()
    }

    private mutating func outputs() -> [Output] {
        if order.count >= 2 {
            var result: [Output] = []
            if drag != nil {
                drag = nil
                result.append(.endDrag)
            }
            let (idA, idB) = (order[0], order[1])
            let a = touches[idA]!, b = touches[idB]!
            if pair == nil || pair!.a != idA || pair!.b != idB {
                touches[idA]?.paired = true
                touches[idB]?.paired = true
                pair = (idA, idB, Self.horizontalDistance(a.hand, b.hand), Self.angle(a.hand, b.hand),
                        (a.hit + b.hit) / 2)
            }
            // Hands nearly together give no usable scale or angle.
            guard let pair, pair.distance > 0.01 else { return result }
            let magnification = Double(Self.horizontalDistance(a.hand, b.hand) / pair.distance)
            let twist = Self.wrapped(Self.angle(a.hand, b.hand) - pair.angle)
            return result + [.magnify(by: magnification, startedAt: pair.start),
                             .rotate(angle: twist, startedAt: pair.start)]
        }
        guard let id = order.first, let touch = touches[id], touch.moved else { return [] }
        if drag?.id != id {
            // Like DragGesture, from where the pinch began, so the travel
            // before the threshold isn't lost.
            drag = touch.paired ? (id, touch.location, touch.hand) : (id, touch.hit, touch.handStart)
        }
        let drag = self.drag!
        return [.drag(from: drag.start, to: drag.start + touch.hand - drag.handStart)]
    }

    /// In the horizontal plane, so raising one hand doesn't zoom.
    private static func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(SIMD2(b.x - a.x, b.z - a.z))
    }

    /// The line from `a` to `b`, counterclockwise about +Y from +X.
    private static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        atan2(-(b.z - a.z), b.x - a.x)
    }

    private static func wrapped(_ angle: Float) -> Float {
        atan2(sin(angle), cos(angle))
    }
}
