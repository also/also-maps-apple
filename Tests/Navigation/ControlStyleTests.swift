import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

private let start = CameraPose(latitude: 37.7955, longitude: -122.3937, height: 900, heading: 25 * degrees,
                               pitch: -33 * degrees)
private let context = NavigationContext(cameraGround: 0, minimumAltitude: 1.5, maximumAltitude: 20_000_000)

private func angleDifference(_ a: Double, _ b: Double) -> Double {
    abs(remainder(a - b, 2 * .pi))
}

struct NavigationOperationTests {
    @Test func climbChangesHeightOnly() {
        let state = NavigationState(camera: start, movementHeading: 1, headingLink: .independent)
        let climbed = NavigationOperations.climb(state, by: 250, context: context)
        #expect(climbed.camera.latitude == start.latitude)
        #expect(climbed.camera.longitude == start.longitude)
        #expect(climbed.camera.heading == start.heading)
        #expect(climbed.camera.pitch == start.pitch)
        #expect(climbed.movementHeading == 1)
        #expect(climbed.camera.height == 1_150)
    }

    @Test func climbIsClampedAboveTheGround() {
        let state = NavigationState(camera: start)
        #expect(NavigationOperations.climb(state, by: -10_000, context: context).camera.height == 1.5)
    }

    @Test func turnMovesTheMovementHeadingOnlyWhenLinked() {
        let linked = NavigationOperations.turn(NavigationState(camera: start, headingLink: .linked), by: 0.5)
        #expect(angleDifference(linked.camera.heading, start.heading + 0.5) < 1e-12)
        #expect(linked.movementHeading == linked.camera.heading)
        #expect(linked.camera.position == start.position)

        let independent = NavigationOperations.turn(
            NavigationState(camera: start, movementHeading: 2, headingLink: .independent), by: 0.5)
        #expect(independent.movementHeading == 2)
    }

    @Test func faceNorthRespectsTheLink() {
        let linked = NavigationOperations.faceNorth(NavigationState(camera: start, headingLink: .linked))
        #expect(linked.camera.heading == 0 && linked.movementHeading == 0)
        let independent = NavigationOperations.faceNorth(
            NavigationState(camera: start, movementHeading: 2, headingLink: .independent))
        #expect(independent.camera.heading == 0 && independent.movementHeading == 2)
    }

    /// Movement follows the movement heading even when the view looks
    /// elsewhere.
    @Test func moveFollowsTheMovementHeading() {
        var camera = start
        camera.heading = 0
        let state = NavigationState(camera: camera, movementHeading: .pi / 2, headingLink: .independent)
        let moved = NavigationOperations.move(state, forward: 1_000, right: 0)
        #expect(moved.camera.longitude > start.longitude + 0.01)
        #expect(abs(moved.camera.latitude - start.latitude) < 1e-3)
        #expect(angleDifference(moved.camera.heading, 0) < 1e-3)
        #expect(moved.camera.height == start.height)
    }

    @Test func flyingOverThePoleContinues() {
        let camera = CameraPose(latitude: 89.9, longitude: -122.3937, height: 900, heading: 0, pitch: -0.5)
        let first = NavigationOperations.move(NavigationState(camera: camera), forward: 50_000, right: 0)
        #expect(abs(first.camera.latitude - 89.65) < 0.01)
        #expect(abs(GeoMath.normalizedLongitude(first.camera.longitude - (camera.longitude + 180))) < 1e-6)
        #expect(angleDifference(first.camera.heading, .pi) < 1e-6)
        #expect(angleDifference(first.movementHeading, .pi) < 1e-6)
        let second = NavigationOperations.move(first, forward: 50_000, right: 0)
        #expect(second.camera.latitude < first.camera.latitude - 0.4)
    }

    @Test func orbitKeepsTheDistanceAndKeepsFacingThePivot() throws {
        let state = NavigationState(camera: start, headingLink: .linked)
        guard case let .hit(pivot, _) = Geodesy.intersect(
            ray: Ray(origin: start.position, direction: start.basis.forward), surfaceHeight: 0) else {
            Issue.record("expected a hit"); return
        }
        let orbited = NavigationOperations.orbit(state, about: pivot, by: .pi / 2, context: context)
        #expect(abs(simd_distance(orbited.camera.position, pivot) - simd_distance(start.position, pivot)) < 1e-6)
        #expect(angleDifference(orbited.camera.heading, start.heading + .pi / 2) < 1e-3)
        #expect(orbited.movementHeading == orbited.camera.heading)
        // The view ray still passes (nearly) through the pivot.
        let forward = orbited.camera.basis.forward
        let toPivot = pivot - orbited.camera.position
        let miss = simd_length(toPivot - forward * simd_dot(toPivot, forward))
        #expect(miss < 1e-3)
    }

    @Test func dollyApproachesTheTarget() {
        let target = Geodesy.ecef(latitude: 37.80, longitude: -122.39, height: 0)
        let state = NavigationState(camera: start)
        let dollied = NavigationOperations.dolly(state, toward: target, fraction: 0.5, context: context)
        let before = simd_distance(start.position, target)
        #expect(abs(simd_distance(dollied.camera.position, target) - before / 2) < 1e-6)
        #expect(angleDifference(dollied.camera.heading, start.heading) < 1e-4)
    }
}

/// The two-style prototype: model flight and orbit/pan/zoom over the same
/// navigation state (docs/camera-core.md §15, stage 1).
struct ControlStyleTests {
    private let flight = ModelFlightStyle()

    @Test func modelFlightClimbKeepsPositionAndScalesAltitude() {
        let state = flight.activate(NavigationState(camera: start))
        let climbed = flight.step(state, input: ControlInput(climb: 1), deltaTime: 0.5, context: context)
        #expect(climbed.camera.latitude == start.latitude)
        #expect(climbed.camera.longitude == start.longitude)
        #expect(abs(climbed.camera.height - 900 * exp(0.5)) < 1e-6)
    }

    @Test func modelFlightLinksTheHeadings() {
        let state = flight.activate(NavigationState(camera: start, movementHeading: 2, headingLink: .independent))
        #expect(state.headingLink == .linked)
        #expect(state.movementHeading == start.heading)
        let turned = flight.step(state, input: ControlInput(turn: 1), deltaTime: 0.25, context: context)
        #expect(turned.movementHeading == turned.camera.heading)
    }

    @Test func switchingStylesKeepsTheView() {
        let flying = flight.activate(NavigationState(camera: start))
        let (orbiting, orbit) = OrbitStyle.activate(flying, surfaceHeight: 0)
        #expect(orbiting.camera == flying.camera)
        #expect(orbiting.headingLink == .independent)
        // The pivot is on the view ray.
        let toPivot = orbit.pivot - start.position
        let forward = start.basis.forward
        #expect(simd_length(toPivot - forward * simd_dot(toPivot, forward)) < 1e-6)

        let back = flight.activate(orbiting)
        #expect(back.camera == orbiting.camera)
        #expect(back.headingLink == .linked)
    }

    @Test func orbitStyleWithoutAHitFallsBackToTheNadir() {
        var camera = start
        camera.pitch = 5 * degrees
        let (state, orbit) = OrbitStyle.activate(NavigationState(camera: camera), surfaceHeight: 0)
        #expect(state.camera == camera)
        let (coordinate, height) = Geodesy.geodetic(orbit.pivot)
        #expect(abs(coordinate.latitude - camera.latitude) < 1e-9)
        #expect(abs(height) < 1e-6)
    }

    @Test func orbitStyleLeavesTheMovementHeadingAlone() {
        var (state, orbit) = OrbitStyle.activate(NavigationState(camera: start), surfaceHeight: 0)
        let movement = state.movementHeading
        state = orbit.step(state, input: ControlInput(turn: 1), deltaTime: 0.5, context: context)
        #expect(angleDifference(state.camera.heading, start.heading + .pi / 6) < 1e-3)
        // Only carried along the globe with the camera (a tiny change), not
        // turned with the view.
        #expect(angleDifference(state.movementHeading, movement) < 1e-3)
    }

    @Test func orbitStylePanCarriesThePivot() {
        var (state, orbit) = OrbitStyle.activate(NavigationState(camera: start), surfaceHeight: 0)
        let before = simd_distance(state.camera.position, orbit.pivot)
        state = orbit.step(state, input: ControlInput(move: SIMD2(0, 1)), deltaTime: 0.2, context: context)
        #expect(abs(simd_distance(state.camera.position, orbit.pivot) - before) < 0.5)
        #expect(state.camera.height == start.height)
    }

    @Test func orbitStyleZoomApproachesThePivot() {
        var (state, orbit) = OrbitStyle.activate(NavigationState(camera: start), surfaceHeight: 0)
        let before = simd_distance(state.camera.position, orbit.pivot)
        state = orbit.step(state, input: ControlInput(dolly: 1), deltaTime: 0.5, context: context)
        #expect(abs(simd_distance(state.camera.position, orbit.pivot) - before * exp(-0.5)) < 1e-3)
    }
}
