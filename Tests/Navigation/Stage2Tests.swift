import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

/// The volume's geometry, as MapPresentation.volume defines it.
private let volume = RoomGeometry(designEye: SIMD3(0, 0.3, 0.85),
                                  placementLevel: SIMD3(0, -0.25, 0),
                                  contentHalfWidth: 0.5,
                                  fullTilt: RoomGeometry.tiltFacing(SIMD3(0, 0, 0), from: SIMD3(0, 0.3, 0.85)))
private let immersive5 = RoomGeometry(designEye: SIMD3(0, 1.6, 0),
                                  placementLevel: SIMD3(0, 0.02, -3.1),
                                  contentHalfWidth: 2.5)
private let sanFrancisco = GeoCoordinate(latitude: 37.7955, longitude: -122.3937)
private let context = NavigationContext(cameraGround: 0, minimumAltitude: 55, maximumAltitude: 20_000_000)

/// The framing the app uses: tilt from the assist.
private func framing(_ camera: CameraPose, _ room: RoomGeometry = volume) -> AdaptiveModel.Framing {
    EyeLevelModel.framing(camera: camera, room: room, groundHeight: 0,
                          tiltWeight: EyeLevelModel.tiltWeight(for: camera))
}

struct PlaceFramingTests {
    @Test(arguments: [600.0, 8_000, 200_000])
    func placeCenterIsTheViewCenterAtTheRequestedScale(radius: Double) {
        let camera = EyeLevelModel.framePlace(center: sanFrancisco, radius: radius, heading: 0.3, room: volume)
        let f = framing(camera)
        let center = Geodesy.ecef(sanFrancisco, height: 0)
        #expect(simd_distance(f.georeference.map(center), f.placementPoint) < 1e-3)
        #expect(abs(f.shownRadius(volume) / radius - 1) < 0.01)
    }

    @Test(arguments: [600.0, 8_000])
    func placesBelowFiftyKilometersLandOnTheContentCenter(radius: Double) {
        let camera = EyeLevelModel.framePlace(center: sanFrancisco, radius: radius, heading: 0.3, room: volume)
        let landed = framing(camera).georeference.map(Geodesy.ecef(sanFrancisco, height: 0))
        // The view center is where the line of sight to C₀ meets the
        // ground, a little past C₀ for the Earth's curve.
        #expect(simd_distance(SIMD2(landed.x, landed.z), SIMD2(0, 0)) < 0.01)
        #expect(abs(landed.y + 0.25) < 0.01)
    }
}

struct PinchManipulationTests {
    /// A pinch from `start` (a place framed at `radius`), grabbing map-frame
    /// point `p`; returns the framing it ends at and the grabbed point.
    private func pinch(grabAt p: SIMD3<Double>, translation: SIMD3<Double> = .zero, magnification: Double,
                       twist: Double, radius: Double = 600,
                       room: RoomGeometry = volume) -> (AdaptiveModel.Framing, SIMD3<Double>, Double) {
        let start = EyeLevelModel.framePlace(center: sanFrancisco, radius: radius, heading: 0.2, room: room)
        let before = framing(start, room)
        let grab = before.georeference.ecef(map: p)
        let scale = before.georeference.scale * magnification
        let grabbed = AdaptiveModel.Grab(point: grab, start: p, startRotation: before.georeference.rotation,
                                         translation: translation, twist: twist)
        let pose = AdaptiveModel.pose(for: grabbed, height: EyeLevelModel.altitude(forScale: scale, room: room),
                                      from: start, eye: room.designEye) { framing($0, room) }
        return (framing(pose, room), grab, scale)
    }

    @Test(arguments: [0.5, 2.0, 5.0])
    func zoomKeepsTheGrabbedPointWhereItWas(magnification: Double) {
        let p = SIMD3(0.2, -0.25, 0.15)
        let (after, grab, scale) = pinch(grabAt: p, magnification: magnification, twist: 0)
        #expect(simd_distance(after.georeference.map(grab), p) < 1e-3)
        #expect(abs(after.georeference.scale / scale - 1) < 1e-9)
    }

    @Test func zoomTwistAndDragTogether() {
        let p = SIMD3(-0.1, -0.25, 0.2)
        let move = SIMD3(0.05, 0, -0.08)
        let (after, grab, scale) = pinch(grabAt: p, translation: move, magnification: 1.7, twist: 40 * degrees)
        #expect(simd_distance(after.georeference.map(grab), p + move) < 1e-3)
        #expect(abs(after.georeference.scale / scale - 1) < 1e-9)
    }

    /// The twist turns the map about the grabbed point's up, counterclockwise
    /// seen from above, so the view heading turns clockwise by as much.
    @Test func twistTurnsAboutTheGrabbedPoint() {
        let p = SIMD3(0.1, -0.25, 0.1)
        let start = EyeLevelModel.framePlace(center: sanFrancisco, radius: 600, heading: 0.2, room: volume)
        let (after, grab, _) = pinch(grabAt: p, magnification: 1, twist: 0.5)
        #expect(simd_distance(after.georeference.map(grab), p) < 1e-3)
        let north = Geodesy.enu(latitude: sanFrancisco.latitude, longitude: sanFrancisco.longitude).north
        let before = framing(start).georeference.rotation.act(north)
        let now = after.georeference.rotation.act(north)
        let angle = atan2(simd_cross(before, now).y, simd_dot(before, now))
        #expect(abs(angle - 0.5) < 1e-3)
    }

    /// Between 50 and 500 km the tilt changes with height, which moves the
    /// globe's center in the room, so the grabbed point can't stay exactly
    /// where it was. The pinch still reaches the scale exactly and keeps the
    /// point where you see it, on the line of sight through where you
    /// pinched.
    @Test(arguments: [0.6, 1.6])
    func zoomWhileTheTiltChanges(magnification: Double) {
        let start = EyeLevelModel.framePlace(center: sanFrancisco, radius: 120_000, heading: 0.2, room: volume)
        let weight = EyeLevelModel.tiltWeight(for: start)
        #expect(weight > 0.1 && weight < 0.9)
        let p = framing(start).placementPoint + SIMD3(0.1, 0, 0.05)
        let (after, grab, scale) = pinch(grabAt: p, magnification: magnification, twist: 0, radius: 120_000)
        #expect(abs(after.georeference.scale / scale - 1) < 1e-9)
        let sight = simd_normalize(p - volume.designEye)
        let seen = simd_normalize(after.georeference.map(grab) - volume.designEye)
        #expect(simd_dot(sight, seen) > 1 - 1e-9)
    }

    /// Zooming steadily from the city out past the tilt range, frame by
    /// frame from the last pose: the scale follows the hands exactly, and
    /// the grabbed point moves only a little each frame (toward the globe's
    /// center as it shrinks, and with the tilt).
    @Test func zoomThroughTheTiltRangeHasNoSteps() {
        var pose = EyeLevelModel.framePlace(center: sanFrancisco, radius: 20_000, heading: 0.2, room: volume)
        let before = framing(pose)
        let p = before.placementPoint + SIMD3(0.15, 0, 0.1)
        let grabbed = AdaptiveModel.Grab(point: before.georeference.ecef(map: p), start: p,
                                         startRotation: before.georeference.rotation)
        var previous = before.georeference.scale
        var previousGrab = p
        for step in 1...200 {
            let scale = before.georeference.scale * pow(0.97, Double(step))
            pose = AdaptiveModel.pose(for: grabbed, height: EyeLevelModel.altitude(forScale: scale, room: volume),
                                      from: pose, eye: volume.designEye) { framing($0) }
            let f = framing(pose)
            #expect(abs(log(f.georeference.scale / previous) - log(0.97)) < 1e-9)
            let at = f.georeference.map(grabbed.point)
            #expect(simd_distance(at, previousGrab) < 0.015)
            previous = f.georeference.scale
            previousGrab = at
        }
        #expect(pose.height > 1_000_000)
    }

    /// Fully zoomed out, dragging rolls the globe: the grabbed point moves
    /// along the surface as far as the hand moves, past the edge and around
    /// the back, and the globe turns a little each frame, with no jumps
    /// (including the spin about the point as it crosses the far side).
    @Test func dragRollsAGlobe() {
        var pose = CameraPose(latitude: 37.79, longitude: -122.39, height: 10_000_000, heading: 0, pitch: -.pi / 2)
        let before = framing(pose)
        let p = before.placementPoint
        let center = before.georeference.map(.zero)
        let radius = simd_distance(center, p)
        var grabbed = AdaptiveModel.Grab(point: before.georeference.ecef(map: p), start: p,
                                         startRotation: before.georeference.rotation)
        let up = simd_normalize(p - center)
        let side = simd_normalize(SIMD3(1, 0, 0) - up * up.x)
        var previous = p
        var previousRotation = before.georeference.rotation
        for step in 1...300 {
            // Up to three globe diameters of hand movement.
            grabbed.translation = side * (6 * radius * Double(step) / 300)
            pose = AdaptiveModel.pose(for: grabbed, height: pose.height, from: pose, eye: volume.designEye) { framing($0) }
            let at = framing(pose).georeference.map(grabbed.point)
            let arc = simd_length(grabbed.translation) / radius
            let expected = center + radius * (up * cos(arc) + side * sin(arc))
            // Within the Earth's flattening of a sphere's roll.
            #expect(simd_distance(at, expected) < 0.02 * radius)
            #expect(simd_distance(at, previous) < 0.03 * radius)
            let rotation = framing(pose).georeference.rotation
            let turn = (rotation * previousRotation.inverse).angle
            #expect(min(turn, 2 * .pi - turn) < 0.03)
            previous = at
            previousRotation = rotation
        }
    }

    /// Zooming out from a flat view to a small globe turns the globe only a
    /// little each step, wherever the pinch began, and an unchanged pinch
    /// leaves it still. (Holding the grabbed point's direction from the
    /// globe's center instead sent it under the globe once the shrinking
    /// globe's center rose past it, spinning the globe up to 1.6 rad in a
    /// step near 9,900 km.)
    @Test(arguments: [0.0, 0.001, 0.15], [20_000.0, 120_000, 300_000, 1_000_000])
    func zoomOutToAGlobeTurnsSmoothly(side: Double, radius: Double) {
        var pose = EyeLevelModel.framePlace(center: sanFrancisco, radius: radius, heading: 0.2, room: volume)
        let before = framing(pose)
        let start = before.placementPoint + SIMD3(side, 0, 0)
        let point = GestureSurface.snap(before.georeference.ecef(map: start), toHeight: 0)
        let grab = AdaptiveModel.Grab(point: point, start: before.georeference.map(point),
                                      startRotation: before.georeference.rotation)
        let startHeight = EyeLevelModel.altitude(forScale: before.georeference.scale, room: volume)
        var previous = before.georeference.rotation
        for step in 1...700 {
            let height = min(11_000_000, startHeight * pow(1.01, Double(step)))
            pose = AdaptiveModel.pose(for: grab, height: height, from: pose, eye: volume.designEye) { framing($0) }
            let rotation = framing(pose).georeference.rotation
            let turn = (rotation * previous.inverse).angle
            #expect(min(turn, 2 * .pi - turn) < 0.1)
            previous = rotation
        }
        for _ in 0..<15 {
            pose = AdaptiveModel.pose(for: grab, height: pose.height, from: pose, eye: volume.designEye) { framing($0) }
            let turn = (framing(pose).georeference.rotation * previous.inverse).angle
            #expect(min(turn, 2 * .pi - turn) < 1e-6)
            previous = framing(pose).georeference.rotation
        }
    }

    /// Zooming in on a point grabbed above the eye, from a tilted globe in
    /// the immersive space: the point stays on the line of sight while the
    /// line meets the globe, then rides the horizon rather than slipping
    /// behind it. (As logged on the headset; the grab used to go to the
    /// globe's point nearest the line, out of sight past the horizon.)
    @Test func zoomInPastTheLineOfSightKeepsTheGrabOnTheHorizon() {
        let room = RoomGeometry(designEye: SIMD3(0.01, 1.10, 0), placementLevel: SIMD3(0, 0.02, -5.6),
                                contentHalfWidth: 5, fullTilt: .pi / 2)
        let ground = 1_000.0
        func frame(_ c: CameraPose) -> AdaptiveModel.Framing {
            EyeLevelModel.framing(camera: c, room: room, groundHeight: ground,
                                  tiltWeight: EyeLevelModel.tiltWeight(for: c))
        }
        var pose = CameraPose(latitude: 44.06, longitude: -117.81, height: 434_000,
                              heading: 7.6 * degrees, pitch: -0.57)
        let before = frame(pose)
        let point = GestureSurface.snap(before.georeference.ecef(map: SIMD3(0.074, 1.395, -1.105)), toHeight: ground)
        let start = before.georeference.map(point)
        let sight = simd_normalize(start - room.designEye)
        let grab = AdaptiveModel.Grab(point: point, start: start, startRotation: before.georeference.rotation)
        var reachedHorizon = false
        for step in 0...60 {
            let scale = before.georeference.scale * pow(1.03, Double(step))
            pose = AdaptiveModel.pose(for: grab, height: ground + EyeLevelModel.altitude(forScale: scale, room: room),
                                      from: pose, eye: room.designEye, frame: frame)
            let after = frame(pose)
            let at = after.georeference.map(point)
            let up = simd_normalize(at - after.georeference.map(.zero))
            let facing = simd_dot(up, simd_normalize(room.designEye - at))
            let off = simd_length(simd_cross(simd_normalize(at - room.designEye), sight))
            #expect(facing > -1e-6)
            if facing > 1e-3 { #expect(off < 1e-6) }
            reachedHorizon = reachedHorizon || facing < 1e-3
        }
        #expect(reachedHorizon)
    }

    /// A hand held still holds the globe still, frame after frame, even
    /// with the grabbed point rolled most of the way to the globe's edge.
    @Test func aStillHandHoldsAGlobeStill() {
        var pose = CameraPose(latitude: 37.79, longitude: -122.39, height: 10_000_000, heading: 0, pitch: -.pi / 2)
        let before = framing(pose)
        let p = before.placementPoint
        let grabbed = AdaptiveModel.Grab(point: before.georeference.ecef(map: p), start: p,
                                         startRotation: before.georeference.rotation,
                                         translation: SIMD3(0.5, 0, 0))
        pose = AdaptiveModel.pose(for: grabbed, height: pose.height, from: pose, eye: volume.designEye) { framing($0) }
        let held = framing(pose).georeference.map(grabbed.point)
        for _ in 0..<10 {
            pose = AdaptiveModel.pose(for: grabbed, height: pose.height, from: pose, eye: volume.designEye) { framing($0) }
            #expect(simd_distance(framing(pose).georeference.map(grabbed.point), held) < 1e-6)
        }
    }

    /// Gestures arrive in the map frame; the pose holds them there, so with
    /// any room placement the grabbed point stays put in the room too.
    @Test func holdsAfterANonIdentityRoomPlacement() {
        let placement = RoomPlacement(translation: SIMD3(0.3, 0, -0.4), yaw: 0.6)
        let handInRoom = SIMD3(0.5, 0.02, -2.6)
        let p = placement.similarity.inverse.apply(handInRoom)
        let (after, grab, _) = pinch(grabAt: p, magnification: 2, twist: 0.3, room: immersive5)
        #expect(simd_distance(placement.similarity.apply(after.georeference.map(grab)), handInRoom) < 1e-3)
    }
}

struct ContinuityTests {
    /// Straight ascent in the volume, tilting with altitude: the
    /// georeference changes by a bounded step per frame, with no jumps, from
    /// the city to orbit.
    @Test func ascentIsContinuous() {
        let flight = ModelFlightStyle()
        var state = flight.activate(NavigationState(
            camera: EyeLevelModel.framePlace(center: sanFrancisco, radius: 600, heading: 0, room: volume)))
        let dt = 1.0 / 90
        var previous = framing(state.camera)
        var largestScaleStep = 0.0, largestMove = 0.0
        for _ in 0..<(90 * 12) {
            state = flight.step(state, input: ControlInput(climb: 1), deltaTime: dt, context: context)
            let current = framing(state.camera)
            largestScaleStep = max(largestScaleStep, abs(log(current.georeference.scale / previous.georeference.scale)))
            // How far a point at the view center moves in the room.
            let probe = previous.georeferencePoint
            largestMove = max(largestMove, simd_distance(current.georeference.map(probe),
                                                         previous.georeference.map(probe)))
            previous = current
        }
        // Climbing at e¹ per second scales by at most e^(1/90) per frame.
        #expect(largestScaleStep < 1.0 / 90 * 1.05)
        #expect(largestMove < 0.02)
        #expect(state.camera.height > 1_000_000)
    }
}

struct AreaOfInterestTests {
    private let viewer = sanFrancisco
    private let ahead = GeoMath.destination(from: sanFrancisco, bearing: 0, distance: 1_000)

    @Test func georeferencePolicyIsTodays() {
        let area = AOIPolicy.georeference(regionMultiplier: 2)
            .area(viewerNadir: viewer, altitude: 600, heading: 0.4, georeferencePoint: ahead, shownRadius: 500)
        #expect(area.center == ahead)
        #expect(area.radius == 1_000)
        #expect(area.heading == 0.4)
    }

    @Test func viewerPolicyReachesAroundTheViewer() {
        let area = AOIPolicy.viewer(reachPerAltitude: 3)
            .area(viewerNadir: viewer, altitude: 600, heading: 0, georeferencePoint: ahead, shownRadius: 500)
        #expect(area.center == viewer)
        #expect(area.radius == 1_800)
    }

    @Test func horizonPolicyReachesEverythingVisible() {
        let area = AOIPolicy.horizon(limitPerAltitude: nil)
            .area(viewerNadir: viewer, altitude: 16_834, heading: 0, georeferencePoint: ahead, shownRadius: 500)
        #expect(area.center == viewer)
        // The horizon from 16.8 km is ~463 km; mountains 3 km high show ~196 km past it.
        #expect(abs(area.radius - 659_000) < 2_000)
        let limited = AOIPolicy.horizon(limitPerAltitude: 10)
            .area(viewerNadir: viewer, altitude: 16_834, heading: 0, georeferencePoint: ahead, shownRadius: 500)
        #expect(limited.radius == 168_340)
    }

    @Test func blendedPolicyCoversViewerAndShownRegion() {
        let near = AOIPolicy.blended(reachPerAltitude: 3, regionMultiplier: 1)
            .area(viewerNadir: viewer, altitude: 600, heading: 0, georeferencePoint: ahead, shownRadius: 500)
        #expect(GeoMath.distance(from: near.center, to: viewer) < 1)
        #expect(near.radius >= 1_000 + 500 - 1)
        let far = AOIPolicy.blended(reachPerAltitude: 3, regionMultiplier: 1)
            .area(viewerNadir: viewer, altitude: 80_000, heading: 0, georeferencePoint: ahead, shownRadius: 60_000)
        #expect(GeoMath.distance(from: far.center, to: ahead) < 1)
        #expect(abs(far.radius - 60_000) < 1)
    }
}

struct GroundEstimateTests {
    private func tile(at coordinate: GeoCoordinate, radius: Double, minimum: Double) -> TileHeightRange {
        TileHeightRange(center: Geodesy.ecef(coordinate, height: minimum), radius: radius,
                        minimumHeight: minimum, maximumHeight: minimum + 50)
    }

    @Test func columnUsesTheMostDetailedCoveringTile() {
        let coarse = tile(at: sanFrancisco, radius: 5_000, minimum: -40)
        let fine = tile(at: sanFrancisco, radius: 200, minimum: 12)
        #expect(GroundEstimates.columnHeight([coarse, fine], at: sanFrancisco) == 12)
        let away = GeoMath.destination(from: sanFrancisco, bearing: 1, distance: 1_000)
        #expect(GroundEstimates.columnHeight([coarse, fine], at: away) == -40)
        #expect(GroundEstimates.columnHeight([fine], at: away) == nil)
    }

    @Test func envelopeIsTheLowestInTheFootprintIncludingCurvature() {
        let near = tile(at: sanFrancisco, radius: 100, minimum: 30)
        let farCenter = GeoMath.destination(from: sanFrancisco, bearing: 2, distance: 50_000)
        let far = tile(at: farCenter, radius: 100, minimum: 30)
        let envelope = GroundEstimates.envelope([near, far], around: sanFrancisco, radius: 60_000, statistic: .minimum)
        #expect(abs(envelope! - (30 - GroundEstimates.curvatureDrop(49_900))) < 1)
        #expect(GroundEstimates.envelope([far], around: sanFrancisco, radius: 1_000, statistic: .minimum) == nil)
    }

    @Test func easedHeightIgnoresSmallChangesAndSettles() {
        var height = EasedHeight(10)
        height.aim(at: 10.3, hysteresis: 0.5)
        #expect(height.target == nil)
        height.aim(at: 20, hysteresis: 0.5)
        for _ in 0..<200 { height.ease(deltaTime: 1.0 / 90) }
        #expect(height.value == 20)
        height.aim(at: .nan)
        #expect(height.target == nil)
    }
}

struct ViewStateTests {
    private func sample(held: Bool) -> MapViewState {
        let camera = EyeLevelModel.framePlace(center: sanFrancisco, radius: 600, heading: 0.5, room: volume)
        let inputs = StreamingInputs(anchor: StreamingAnchor(coordinate: sanFrancisco, height: -30),
                                     lod: .orbit(heading: 0.5, elevation: 0.6, distance: 1_000),
                                     regionHeading: 0.5, streamingRadius: 700)
        return MapViewState(navigation: NavigationState(camera: camera, movementHeading: 0.1, headingLink: .independent),
                            rayHeight: -31, envelopeHeight: -33, host: "immersive5x",
                            roomPlacement: RoomPlacement(translation: SIMD3(0.1, 0, -0.2), yaw: 0.25),
                            heldStreaming: held ? inputs : nil, settings: StreamingSettings())
    }

    @Test(arguments: [false, true])
    func roundTripsNavigationAndHeldStreaming(held: Bool) throws {
        let state = sample(held: held)
        let restored = try MapViewState.parse(state.json())
        let a = state.navigationState, b = restored.navigationState
        #expect(abs(a.camera.latitude - b.camera.latitude) < 1e-12)
        #expect(abs(a.camera.height - b.camera.height) < 1e-9)
        #expect(abs(a.camera.pitch - b.camera.pitch) < 1e-12)
        #expect(abs(a.movementHeading - b.movementHeading) < 1e-12)
        #expect(b.headingLink == .independent)
        #expect(restored.host == "immersive5x")
        #expect(restored.tiles == (held ? "held" : "live"))
        #expect(restored.heldStreaming == state.heldStreaming)
        #expect(abs(restored.roomPlacement.placement.yaw - 0.25) < 1e-12)
    }

    @Test func legacyStatesAreRejectedClearly() {
        let legacy = #"{"focusHeight":-32,"headingDegrees":25,"latitude":37.7955,"longitude":-122.3937,"presentation":"volume","radius":600}"#
        #expect(throws: MapViewState.ParseError.unsupportedVersion) { try MapViewState.parse(legacy) }
        #expect(throws: MapViewState.ParseError.notAViewState) { try MapViewState.parse("hello") }
    }

    @Test func invalidStatesAreRejected() throws {
        var state = sample(held: false)
        state.camera.pitchDegrees = 120
        #expect(throws: MapViewState.ParseError.self) { try MapViewState.parse(state.json()) }
        state = sample(held: false)
        state.tiles = "held"
        #expect(throws: MapViewState.ParseError.self) { try MapViewState.parse(state.json()) }
    }
}
