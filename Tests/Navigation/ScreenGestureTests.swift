import Foundation
import simd
import Testing

private let degrees = Double.pi / 180
private let ground = 20.0
private let viewport = ScreenViewport(size: SIMD2(402, 874), fieldOfView: .pi / 4)
private let context = NavigationContext(cameraGround: ground, minimumAltitude: 2, maximumAltitude: 22_000)

private func state(height: Double = 1_020, heading: Double = 30 * degrees,
                   pitch: Double = -35 * degrees) -> NavigationState {
    NavigationState(camera: CameraPose(latitude: 37.78, longitude: -122.39, height: height,
                                       heading: heading, pitch: pitch))
}

private func hit(_ state: NavigationState, _ point: SIMD2<Double>) -> SIMD3<Double>? {
    ScreenGestures.groundPoint(camera: state.camera, point: point, viewport: viewport, groundHeight: ground)
}

struct ScreenGestureTests {
    @Test
    func theCenterOfTheScreenIsTheViewRay() {
        let start = state()
        let ray = ScreenGestures.ray(camera: start.camera, point: viewport.center, viewport: viewport)
        #expect(simd_distance(ray.direction, start.camera.basis.forward) < 1e-12)
    }

    @Test
    func theTopOfTheScreenLooksHigherThanTheBottom() {
        let start = state()
        let top = ScreenGestures.ray(camera: start.camera, point: SIMD2(201, 0), viewport: viewport)
        let bottom = ScreenGestures.ray(camera: start.camera, point: SIMD2(201, 874), viewport: viewport)
        let up = start.camera.basis.up
        #expect(simd_dot(top.direction, up) > simd_dot(bottom.direction, up))
        #expect(abs(acos(simd_dot(top.direction, bottom.direction)) - viewport.fieldOfView) < 1e-9)
    }

    @Test
    func skyPointsStillFindGroundNotTooFarAway() throws {
        let start = state(pitch: -2 * degrees)
        let point = try #require(hit(start, SIMD2(201, 50)))
        #expect(simd_distance(point, start.camera.position) < 100_000)
    }

    @Test(arguments: [SIMD2(201.0, 600), SIMD2(60, 300), SIMD2(350, 800)])
    func panningKeepsTheGroundUnderTheFinger(to: SIMD2<Double>) throws {
        let start = state()
        let grab = try #require(hit(start, SIMD2(201, 500)))
        let moved = ScreenGestures.pan(start, grab: grab, to: to, viewport: viewport, groundHeight: ground)
        let after = try #require(hit(moved, to))
        #expect(simd_distance(after, grab) < 0.5)
        #expect(abs(moved.camera.height - start.camera.height) < 1e-6)
        #expect(abs(moved.camera.pitch - start.camera.pitch) < 1e-9)
    }

    @Test
    func zoomingHalvesTheDistanceAndKeepsTheView() throws {
        let start = state()
        let pivot = try #require(hit(start, SIMD2(120, 600)))
        let zoomed = ScreenGestures.zoom(start, about: pivot, scale: 2, context: context)
        let before = simd_distance(start.camera.position, pivot)
        #expect(abs(simd_distance(zoomed.camera.position, pivot) - before / 2) < 1e-3)
        #expect(abs(zoomed.camera.pitch - start.camera.pitch) < 1e-3)
    }

    @Test
    func zoomingOutMovesAway() throws {
        let start = state()
        let pivot = try #require(hit(start, viewport.center))
        let zoomed = ScreenGestures.zoom(start, about: pivot, scale: 0.5, context: context)
        #expect(zoomed.camera.height > start.camera.height)
    }

    @Test
    func tiltingKeepsThePivotOnScreenAndLevelsTheView() throws {
        let start = state()
        let pivot = try #require(hit(start, viewport.center))
        let tilted = NavigationOperations.tilt(start, about: pivot, by: 15 * degrees,
                                               range: (-Double.pi / 2)...ScreenGestures.levelestTilt, context: context)
        #expect(abs(tilted.camera.pitch - (start.camera.pitch + 15 * degrees)) < 1e-3)
        #expect(tilted.camera.height < start.camera.height)
        let after = try #require(hit(tilted, viewport.center))
        #expect(simd_distance(after, pivot) < 0.5)
    }

    @Test
    func tiltStopsShortOfLevelAndDoesNotJumpFromOutsideTheRange() throws {
        let range = (-Double.pi / 2)...ScreenGestures.levelestTilt
        let start = state(pitch: -5 * degrees)
        let pivot = try #require(hit(start, viewport.center))
        let leveled = NavigationOperations.tilt(start, about: pivot, by: 30 * degrees, range: range, context: context)
        #expect(abs(leveled.camera.pitch - ScreenGestures.levelestTilt) < 1e-2)

        let lookingUp = state(pitch: 10 * degrees)
        let unchanged = NavigationOperations.tilt(lookingUp, about: pivot, by: 5 * degrees, range: range, context: context)
        #expect(unchanged.camera.pitch == lookingUp.camera.pitch)
    }
}

struct TwoFingerClassifierTests {
    @Test
    func smallMovementsDecideNothing() {
        var classifier = TwoFingerClassifier()
        #expect(classifier.update(translation: SIMD2(2, 5), scale: 1.01, rotation: 0.01) == .undecided)
    }

    @Test
    func bothFingersUpOrDownTilts() {
        var classifier = TwoFingerClassifier()
        #expect(classifier.update(translation: SIMD2(3, -20), scale: 1.01, rotation: 0) == .tilt)
    }

    @Test
    func pinchingTwistingOrSlidingSidewaysFollows() {
        var pinch = TwoFingerClassifier(), twist = TwoFingerClassifier(), slide = TwoFingerClassifier()
        #expect(pinch.update(translation: .zero, scale: 1.2, rotation: 0) == .follow)
        #expect(twist.update(translation: .zero, scale: 1, rotation: 0.2) == .follow)
        #expect(slide.update(translation: SIMD2(30, 4), scale: 1, rotation: 0) == .follow)
    }

    @Test
    func theDecisionHoldsForTheWholeGesture() {
        var classifier = TwoFingerClassifier()
        _ = classifier.update(translation: SIMD2(0, 30), scale: 1, rotation: 0)
        #expect(classifier.update(translation: SIMD2(0, 30), scale: 1.5, rotation: 0.5) == .tilt)
    }
}

struct ScrollGestureTests {
    private func action(_ delta: SIMD2<Double>, precise: Bool = true, inverted: Bool = false,
                        zooms: Bool = false, tilts: Bool = false) -> ScrollGesture.Action {
        ScrollGesture(delta: delta, isPrecise: precise, isInverted: inverted, zooms: zooms, tilts: tilts).action
    }

    @Test
    func aTrackpadPansAlongWithTheFingers() {
        #expect(action(SIMD2(12, -5)) == .pan(SIMD2(12, -5)))
    }

    @Test
    func aWheelZoomsWhateverTheScrollDirectionSetting() {
        // The same push away, reported with and without natural scrolling.
        #expect(action(SIMD2(0, 2), precise: false) == .zoom(doublings: 0.5))
        #expect(action(SIMD2(0, -2), precise: false, inverted: true) == .zoom(doublings: 0.5))
    }

    @Test
    func optionZoomsATrackpad() {
        #expect(action(SIMD2(0, 60), zooms: true) == .zoom(doublings: 0.5))
    }

    @Test
    func shiftTiltsWithEither() {
        #expect(action(SIMD2(0, 30), tilts: true) == .tilt(30))
        // The system reports Shift-wheel scrolling as horizontal.
        #expect(action(SIMD2(3, 0), precise: false, tilts: true) == .tilt(30))
    }

    @Test
    func aSidewaysWheelAndAnEmptyScrollDoNothing() {
        #expect(action(.zero) == .none)
        #expect(action(SIMD2(5, 0), zooms: true) == .none)
    }
}
