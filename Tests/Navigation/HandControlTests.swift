import Foundation
import simd
import Testing

// Synthetic hands, in metres: the wrist at `at`, fingers along −z (away
// from the viewer), each straight or curled back toward the palm.
private func finger(base: SIMD3<Float>, straight: Bool) -> HandJoints.Finger {
    if straight {
        return .init(knuckle: base, intermediateBase: base + [0, 0, -0.04],
                     intermediateTip: base + [0, 0, -0.065], tip: base + [0, 0, -0.085])
    }
    // Curled: out, down and back.
    return .init(knuckle: base, intermediateBase: base + [0, 0, -0.04],
                 intermediateTip: base + [0, -0.025, -0.03], tip: base + [0, -0.02, -0.01])
}

private func hand(at wrist: SIMD3<Float> = [0, 1, -0.4], index: Bool, others: Bool,
                  thumbToIndex: Float = 0.08) -> HandJoints {
    let indexFinger = finger(base: wrist + [0, 0, -0.09], straight: index)
    return HandJoints(wrist: wrist, thumbTip: indexFinger.tip + [thumbToIndex, 0, 0],
                      index: indexFinger,
                      middle: finger(base: wrist + [0.02, 0, -0.09], straight: others),
                      ring: finger(base: wrist + [0.04, 0, -0.085], straight: others),
                      little: finger(base: wrist + [0.06, 0, -0.08], straight: others))
}

private let pointing = hand(index: true, others: false)
private let open = hand(index: true, others: true)
private let fist = hand(index: false, others: false, thumbToIndex: 0.05)

struct HandPoseTests {
    @Test func straightnessSeparatesStraightFromCurled() throws {
        #expect(finger(base: .zero, straight: true).straightness > 0.99)
        #expect(finger(base: .zero, straight: false).straightness < 0.6)
    }

    @Test func recognisesPointOpenAndFist() throws {
        var detector = HandPoseDetector()
        detector.update(pointing)
        #expect(detector.isPointing && !detector.isFist)
        detector.update(open)
        #expect(!detector.isPointing && !detector.isFist)
        detector.update(fist)
        #expect(!detector.isPointing && detector.isFist)
        detector.update(nil)
        #expect(!detector.isPointing && !detector.isFist && !detector.isPinching)
    }

    @Test func pinchHasHysteresis() throws {
        var pinch = Hysteresis(enter: 0.015, leave: 0.03)
        // Between the thresholds it stays as it was.
        let states = [0.02, 0.01, 0.025, 0.035, 0.025].map { pinch.update(Float($0)) }
        #expect(states == [false, true, true, false, false])
    }

    @Test func pinchingIndexIsNotPointing() throws {
        var detector = HandPoseDetector()
        detector.update(hand(index: true, others: false, thumbToIndex: 0.005))
        #expect(detector.isPinching && !detector.isPointing)
    }
}

struct HandControllerTests {
    @Test func noneDoesNothing() throws {
        var controller = HandControlController(scheme: .none)
        let (actions, overlay) = controller.update(left: fist, right: pointing, deltaTime: 1 / 90)
        #expect(actions.isEmpty)
        #expect(overlay == HandOverlay())
    }

    @Test func pointAndJumpJumpsOncePerPinch() throws {
        var controller = HandControlController(scheme: .pointAndJump)
        let pinched = hand(at: [-0.3, 1, -0.4], index: true, others: true, thumbToIndex: 0.005)
        let relaxed = hand(at: [-0.3, 1, -0.4], index: true, others: true)
        var (actions, overlay) = controller.update(left: relaxed, right: pointing, deltaTime: 1 / 90)
        #expect(actions.isEmpty)
        let ray = try #require(overlay.pointer)
        #expect(simd_distance(ray.origin, pointing.index.tip) < 1e-5)
        #expect(simd_distance(ray.direction, [0, 0, -1]) < 1e-5)
        (actions, overlay) = controller.update(left: pinched, right: pointing, deltaTime: 1 / 90)
        #expect(actions == [.jumpToPointer])
        #expect(overlay.emphasis == 1)
        (actions, _) = controller.update(left: pinched, right: pointing, deltaTime: 1 / 90)
        #expect(actions.isEmpty)  // Held: no repeat.
        (actions, _) = controller.update(left: relaxed, right: pointing, deltaTime: 1 / 90)
        (actions, _) = controller.update(left: pinched, right: pointing, deltaTime: 1 / 90)
        #expect(actions == [.jumpToPointer])
    }

    @Test func pinchWithoutPointingDoesNotJump() throws {
        var controller = HandControlController(scheme: .pointAndJump)
        let pinched = hand(at: [-0.3, 1, -0.4], index: true, others: true, thumbToIndex: 0.005)
        let (actions, overlay) = controller.update(left: pinched, right: open, deltaTime: 1 / 90)
        #expect(actions.isEmpty)
        #expect(overlay.pointer == nil)
    }

    @Test func pointToFlySteersAlongTheRayByPinch() throws {
        var controller = HandControlController(scheme: .pointToFly)
        let relaxed = hand(at: [-0.3, 1, -0.4], index: true, others: true, thumbToIndex: 0.08)
        var (actions, _) = controller.update(left: relaxed, right: pointing, deltaTime: 1 / 90)
        #expect(actions.isEmpty)
        let half = hand(at: [-0.3, 1, -0.4], index: true, others: true, thumbToIndex: 0.035)
        (actions, _) = controller.update(left: half, right: pointing, deltaTime: 1 / 90)
        guard case let .steer(input) = try #require(actions.first) else {
            Issue.record("expected steering")
            return
        }
        // Pointing straight ahead: forward only, part throttle.
        #expect(input.move.y > 0.3 && input.move.y < 0.6)
        #expect(abs(input.move.x) < 1e-6 && abs(input.climb) < 1e-6)
    }

    @Test func steeringMapsDirectionsToMoveAndClimb() throws {
        let right = HandControlController.steering(direction: [1, 0, 0], throttle: 1)
        #expect(right.move == SIMD2(1, 0) && right.climb == 0)
        let up = HandControlController.steering(direction: simd_normalize([0, 1, -1]), throttle: 0.5)
        #expect(abs(up.move.y - 0.5 * 0.5.squareRoot()) < 1e-6)
        #expect(abs(up.climb - 0.5 * 0.5.squareRoot()) < 1e-6)
    }

    @Test func throttleRange() throws {
        #expect(HandControlController.throttle(pinchDistance: 0.08) == 0)
        #expect(HandControlController.throttle(pinchDistance: 0.01) == 1)
        #expect(abs(HandControlController.throttle(pinchDistance: 0.0375) - 0.5) < 1e-6)
    }

    @Test func oneFistDragsAndReleasing() throws {
        var controller = HandControlController(scheme: .grabWorld)
        var (actions, overlay) = controller.update(left: nil, right: fist, deltaTime: 1 / 90)
        let start = fist.grabPoint
        #expect(actions == [.grab(start: start, current: start, magnification: nil, twist: nil)])
        #expect(overlay.grabs == [start])
        let moved = hand(at: [0.1, 1, -0.4], index: false, others: false, thumbToIndex: 0.05)
        (actions, _) = controller.update(left: nil, right: moved, deltaTime: 1 / 90)
        #expect(actions == [.grab(start: start, current: moved.grabPoint, magnification: nil, twist: nil)])
        (actions, _) = controller.update(left: nil, right: open, deltaTime: 1 / 90)
        #expect(actions == [.endGrab])
    }

    @Test func twoFistsZoomAndTurnAboutTheirMidpoint() throws {
        var controller = HandControlController(scheme: .grabWorld)
        func fistAt(_ x: Float, _ z: Float) -> HandJoints {
            hand(at: [x, 1, z + 0.09], index: false, others: false, thumbToIndex: 0.05)
        }
        // Start 0.4 m apart along x, then the right hand also grabs.
        _ = controller.update(left: fistAt(-0.2, -0.5), right: nil, deltaTime: 1 / 90)
        var (actions, _) = controller.update(left: fistAt(-0.2, -0.5), right: fistAt(0.2, -0.5), deltaTime: 1 / 90)
        #expect(actions.first == .endGrab)
        // Twice as far apart, and turned a quarter turn counterclockwise
        // seen from above (right hand now ahead).
        (actions, _) = controller.update(left: fistAt(0, -0.1), right: fistAt(0, -0.9), deltaTime: 1 / 90)
        guard case let .grab(_, _, magnification, twist) = try #require(actions.first) else {
            Issue.record("expected a grab")
            return
        }
        #expect(abs(try #require(magnification) - 2) < 1e-4)
        #expect(abs(try #require(twist) - .pi / 2) < 1e-4)
    }

    @Test func resetEndsAGrab() throws {
        var controller = HandControlController(scheme: .grabWorld)
        _ = controller.update(left: fist, right: nil, deltaTime: 1 / 90)
        let first = controller.reset(), second = controller.reset()
        #expect(first == [.endGrab])
        #expect(second.isEmpty)
    }
}

struct RaySmootherTests {
    @Test func firstRayPassesThroughThenEases() throws {
        var smoother = RaySmoother(timeConstant: 0.1)
        let a = HandRay(origin: .zero, direction: [0, 0, -1])
        let first = smoother.update(a, deltaTime: 1 / 90)
        #expect(first == a)
        let b = HandRay(origin: [1, 0, 0], direction: [1, 0, 0])
        let next = smoother.update(b, deltaTime: 1 / 90)
        let eased = try #require(next)
        #expect(eased.origin.x > 0 && eased.origin.x < 0.2)
        #expect(abs(simd_length(eased.direction) - 1) < 1e-5)
        let lost = smoother.update(nil, deltaTime: 1 / 90)
        let again = smoother.update(b, deltaTime: 1 / 90)
        #expect(lost == nil)
        #expect(again == b)
    }
}

struct MapRaycastTests {
    @Test func rayDownFromTheEyeHitsTheGroundBelow() throws {
        // Level placement over San Francisco at 1:1000: the eye 1.6 m up is
        // 1,600 m above the ground.
        let camera = CameraPose(latitude: 37.7955, longitude: -122.3937, height: 1_600, heading: 0, pitch: 0)
        let room = RoomGeometry(designEye: [0, 1.6, 0], placementLevel: [0, 0, -5.6],
                                placementDown: [0, 0, 0], contentHalfWidth: 5)
        let framing = EyeLevelModel.framing(camera: camera, room: room, groundHeight: 0, tiltWeight: 0)
        let roomFromECEF = framing.georeference.similarity
        let down = HandRay(origin: [0, 1.6, 0], direction: [0, -1, 0])
        let hit = try #require(MapRaycast.hit(down, roomFromECEF: roomFromECEF, surfaceHeight: 0))
        let (coordinate, height) = Geodesy.geodetic(hit)
        #expect(abs(height) < 0.01)
        #expect(GeoMath.distance(from: coordinate, to: camera.coordinate) < 0.5)
        let up = MapRaycast.up(at: hit, roomFromECEF: roomFromECEF)
        #expect(simd_distance(up, [0, 1, 0]) < 1e-6)
        // Ahead and down at 45°: 1,600 m north.
        let ahead = HandRay(origin: [0, 1.6, 0], direction: simd_normalize([0, -1, -1]))
        let aheadHit = try #require(MapRaycast.hit(ahead, roomFromECEF: roomFromECEF, surfaceHeight: 0))
        let aheadCoordinate = Geodesy.geodetic(aheadHit).coordinate
        #expect(abs(GeoMath.distance(from: aheadCoordinate, to: camera.coordinate) - 1_600) < 5)
        #expect(aheadCoordinate.latitude > camera.latitude)
        // Up: the sky.
        #expect(MapRaycast.hit(HandRay(origin: [0, 1.6, 0], direction: [0, 1, 0]),
                               roomFromECEF: roomFromECEF, surfaceHeight: 0) == nil)
    }
}

struct CameraFlightTests {
    private let start = CameraPose(latitude: 37.7955, longitude: -122.3937, height: 500, heading: 0.3, pitch: 0)

    @Test func endsExactlyAtTheTargetAndStartsAtTheStart() throws {
        var end = start
        end.latitude += 0.05
        end.heading = 0.35
        var flight = CameraFlight(from: start, to: end, altitude: 500)
        #expect(flight.pose(at: 0) == start)
        var pose = start
        for _ in 0..<1_000 where !flight.isFinished { pose = flight.advance(by: 1 / 90) }
        #expect(flight.isFinished)
        #expect(abs(pose.latitude - end.latitude) < 1e-9 && abs(pose.longitude - end.longitude) < 1e-9)
        #expect(abs(pose.height - end.height) < 1e-6 && abs(pose.heading - end.heading) < 1e-9)
    }

    @Test func hopsOnlyWhenFarAndTakesLonger() throws {
        var near = start
        near.latitude += 0.001  // ~110 m at 500 m altitude
        let short = CameraFlight(from: start, to: near, altitude: 500)
        #expect(short.hop == 0)
        var far = start
        far.latitude += 0.5  // ~55 km
        let long = CameraFlight(from: start, to: far, altitude: 500)
        #expect(long.hop > 0 && long.hop <= 20 * 500)
        #expect(long.pose(at: 0.5).height > start.height + long.hop * 0.9)
        #expect(long.duration > short.duration && long.duration <= 4)
    }

    @Test func headingTurnsTheShortWay() throws {
        var end = start
        end.heading = -3.0
        var from = start
        from.heading = 3.0
        let flight = CameraFlight(from: from, to: end, altitude: 500)
        let mid = flight.pose(at: 0.5).heading
        // Through ±π, not through 0.
        #expect(abs(abs(mid) - .pi) < 0.2)
    }
}
