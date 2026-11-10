import simd
import Testing

private typealias Gestures = PinchGestures<Int>

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 1e-5 }

struct PinchGestureTests {
    @Test
    func aStillPinchDoesNothing() {
        var gestures = Gestures()
        #expect(gestures.begin(1, hand: [0, 1, -0.4], hit: [0, 0, -5]).isEmpty)
        #expect(gestures.move(1, hand: [0.005, 1, -0.4]).isEmpty)
        #expect(gestures.end(1).isEmpty)
    }

    @Test
    func aDragCarriesThePinchedPointWithTheHand() {
        var gestures = Gestures()
        _ = gestures.begin(1, hand: [0, 1, -0.4], hit: [0, 0, -5])
        let outputs = gestures.move(1, hand: [0.1, 1, -0.3])
        guard case let .drag(from, to) = outputs.first else { Issue.record("no drag"); return }
        #expect(close(from, [0, 0, -5]))
        #expect(close(to, [0.1, 0, -4.9]))
        #expect(gestures.end(1) == [.endDrag])
    }

    @Test
    func handsMovingApartMagnifyAboutTheMidpoint() throws {
        var gestures = Gestures()
        _ = gestures.begin(1, hand: [-0.1, 1, -0.4], hit: [-1, 0, -5])
        let both = gestures.begin(2, hand: [0.1, 1, -0.4], hit: [1, 0, -5])
        #expect(both.contains(.magnify(by: 1, startedAt: [0, 0, -5])))
        // Raising a hand doesn't zoom: only horizontal separation counts.
        let outputs = gestures.move(2, hand: [0.3, 1.2, -0.4])
        let magnify = try #require(outputs.first { if case .magnify = $0 { true } else { false } })
        guard case let .magnify(by, start) = magnify else { return }
        #expect(abs(by - 2) < 1e-5)
        #expect(close(start, [0, 0, -5]))
    }

    @Test
    func twistingCounterclockwiseFromAboveIsPositive() throws {
        var gestures = Gestures()
        _ = gestures.begin(1, hand: [-0.1, 1, 0], hit: [0, 0, -5])
        _ = gestures.begin(2, hand: [0.1, 1, 0], hit: [0, 0, -5])
        // The right hand moves away from the viewer (−Z): seen from above, the
        // line between the hands turns counterclockwise.
        let outputs = gestures.move(2, hand: [0.1, 1, -0.2])
        let rotate = try #require(outputs.first { if case .rotate = $0 { true } else { false } })
        guard case let .rotate(angle, _) = rotate else { return }
        #expect(angle > 0)
        #expect(abs(angle - atan2(0.2, 0.2)) < 1e-5)
    }

    @Test
    func theSecondHandEndsTheDragAndLiftingItResumesDraggingWithoutAJump() {
        var gestures = Gestures()
        _ = gestures.begin(1, hand: [0, 1, -0.4], hit: [0, 0, -5])
        _ = gestures.move(1, hand: [0.1, 1, -0.4])
        let both = gestures.begin(2, hand: [0.3, 1, -0.4], hit: [2, 0, -5])
        #expect(both.first == .endDrag)
        _ = gestures.move(1, hand: [0.2, 1, -0.4])
        let lifted = gestures.end(2)
        #expect(Array(lifted.prefix(2)) == [.endMagnify, .endRotate])
        // The remaining hand drags on from its point's current place.
        guard case let .drag(from, to) = lifted.last else { Issue.record("no drag"); return }
        #expect(close(from, [0.2, 0, -5]))
        #expect(close(to, from))
        guard case let .drag(_, next) = gestures.move(1, hand: [0.25, 1, -0.4]).first else {
            Issue.record("no drag"); return
        }
        #expect(close(next, [0.25, 0, -5]))
    }

    @Test
    func unknownPinchesAreIgnored() {
        var gestures = Gestures()
        #expect(gestures.move(7, hand: [0, 1, 0]).isEmpty)
        #expect(gestures.end(7).isEmpty)
        #expect(!gestures.isTracking(7))
    }
}
