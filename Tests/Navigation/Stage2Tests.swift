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
    func placeCentreIsTheViewCentreAtTheRequestedScale(radius: Double) {
        let camera = EyeLevelModel.framePlace(centre: sanFrancisco, radius: radius, heading: 0.3, room: volume)
        let f = framing(camera)
        let centre = Geodesy.ecef(sanFrancisco, height: 0)
        #expect(simd_distance(f.georeference.map(centre), f.placementPoint) < 1e-3)
        #expect(abs(f.shownRadius(volume) / radius - 1) < 0.01)
    }

    @Test(arguments: [600.0, 8_000])
    func placesBelowFiftyKilometresLandOnTheContentCentre(radius: Double) {
        let camera = EyeLevelModel.framePlace(centre: sanFrancisco, radius: radius, heading: 0.3, room: volume)
        let landed = framing(camera).georeference.map(Geodesy.ecef(sanFrancisco, height: 0))
        // The view centre is where the line of sight to C₀ meets the
        // ground, a little past C₀ for the Earth's curve.
        #expect(simd_distance(SIMD2(landed.x, landed.z), SIMD2(0, 0)) < 0.01)
        #expect(abs(landed.y + 0.25) < 0.01)
    }
}

struct AnchoredManipulationTests {
    private func solve(grabAt p: SIMD3<Double>, to target: SIMD3<Double>, magnification: Double,
                       twist: Double, radius: Double = 600,
                       room: RoomGeometry = volume) -> (AdaptiveModel.Framing, SIMD3<Double>, Double, Double) {
        let start = EyeLevelModel.framePlace(centre: sanFrancisco, radius: radius, heading: 0.2, room: room)
        let before = framing(start, room)
        let grab = before.georeference.ecef(map: p)
        let anchor = AdaptiveModel.AnchorTarget(
            grab: grab, target: target, scale: before.georeference.scale * magnification,
            heading: start.heading + twist, headingOrigin: start.coordinate)
        let solution = AdaptiveModel.solve(anchor, from: start, room: room, scaleSurface: 0,
                                           context: context) { framing($0, room) }
        let after = framing(solution.pose, room)
        return (after, grab, before.georeference.scale * magnification, solution.error)
    }

    @Test(arguments: [0.5, 2.0, 5.0])
    func pinchKeepsTheGrabbedPointUnderTheHand(magnification: Double) {
        let p = SIMD3(0.2, -0.25, 0.15)
        let (after, grab, scale, _) = solve(grabAt: p, to: p, magnification: magnification, twist: 0)
        #expect(simd_distance(after.georeference.map(grab), p) < 1e-3)
        #expect(abs(after.georeference.scale / scale - 1) < 1e-3)
    }

    @Test func pinchTwistAndDragTogether() {
        let p = SIMD3(-0.1, -0.25, 0.2)
        let target = p + SIMD3(0.05, 0, -0.08)
        let (after, grab, scale, _) = solve(grabAt: p, to: target, magnification: 1.7, twist: 40 * degrees)
        #expect(simd_distance(after.georeference.map(grab), target) < 1e-3)
        #expect(abs(after.georeference.scale / scale - 1) < 1e-3)
    }

    /// Between 50 and 500 km the tilt changes with the height the pinch
    /// asks for, turning the ground about the eye, so the grabbed point
    /// can't stay exactly under the hand: the solve reaches the scale and
    /// keeps the point as close as it can. (×1.6 at 120 km: the ground turns
    /// about 19°.) A known limit of tilting about the eye; see
    /// notes/volume-placement.md.
    @Test(arguments: [0.6, 1.6])
    func pinchWhileTheTiltChangesReachesTheScale(magnification: Double) {
        let start = EyeLevelModel.framePlace(centre: sanFrancisco, radius: 120_000, heading: 0.2, room: volume)
        let weight = EyeLevelModel.tiltWeight(for: start)
        #expect(weight > 0.1 && weight < 0.9)
        let p = framing(start).placementPoint + SIMD3(0.1, 0, 0.05)
        let (after, grab, scale, _) = solve(grabAt: p, to: p, magnification: magnification, twist: 0,
                                            radius: 120_000)
        #expect(abs(after.georeference.scale / scale - 1) < 1e-3)
        #expect(simd_distance(after.georeference.map(grab), p) < 0.15)
    }

    /// Gestures arrive in the reference space and pass through the room
    /// placement first; the solve then holds in the map frame, so the grab
    /// stays under the hand in the room too.
    @Test func holdsAfterANonIdentityRoomPlacement() {
        let placement = RoomPlacement(translation: SIMD3(0.3, 0, -0.4), yaw: 0.6)
        // On the base plane, where the gesture slab is.
        let handInRoom = SIMD3(0.5, 0.02, -2.6)
        let p = placement.similarity.inverse.apply(handInRoom)
        let (after, grab, _, _) = solve(grabAt: p, to: p, magnification: 2, twist: 0.3, room: immersive5)
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
            camera: EyeLevelModel.framePlace(centre: sanFrancisco, radius: 600, heading: 0, room: volume)))
        let dt = 1.0 / 90
        var previous = framing(state.camera)
        var largestScaleStep = 0.0, largestMove = 0.0
        for _ in 0..<(90 * 12) {
            state = flight.step(state, input: ControlInput(climb: 1), deltaTime: dt, context: context)
            let current = framing(state.camera)
            largestScaleStep = max(largestScaleStep, abs(log(current.georeference.scale / previous.georeference.scale)))
            // How far a point at the view centre moves in the room.
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
        #expect(area.centre == ahead)
        #expect(area.radius == 1_000)
        #expect(area.heading == 0.4)
    }

    @Test func viewerPolicyReachesAroundTheViewer() {
        let area = AOIPolicy.viewer(reachPerAltitude: 3)
            .area(viewerNadir: viewer, altitude: 600, heading: 0, georeferencePoint: ahead, shownRadius: 500)
        #expect(area.centre == viewer)
        #expect(area.radius == 1_800)
    }

    @Test func horizonPolicyReachesEverythingVisible() {
        let area = AOIPolicy.horizon(limitPerAltitude: nil)
            .area(viewerNadir: viewer, altitude: 16_834, heading: 0, georeferencePoint: ahead, shownRadius: 500)
        #expect(area.centre == viewer)
        // The horizon from 16.8 km is ~463 km; mountains 3 km high show ~196 km past it.
        #expect(abs(area.radius - 659_000) < 2_000)
        let limited = AOIPolicy.horizon(limitPerAltitude: 10)
            .area(viewerNadir: viewer, altitude: 16_834, heading: 0, georeferencePoint: ahead, shownRadius: 500)
        #expect(limited.radius == 168_340)
    }

    @Test func blendedPolicyCoversViewerAndShownRegion() {
        let near = AOIPolicy.blended(reachPerAltitude: 3, regionMultiplier: 1)
            .area(viewerNadir: viewer, altitude: 600, heading: 0, georeferencePoint: ahead, shownRadius: 500)
        #expect(GeoMath.distance(from: near.centre, to: viewer) < 1)
        #expect(near.radius >= 1_000 + 500 - 1)
        let far = AOIPolicy.blended(reachPerAltitude: 3, regionMultiplier: 1)
            .area(viewerNadir: viewer, altitude: 80_000, heading: 0, georeferencePoint: ahead, shownRadius: 60_000)
        #expect(GeoMath.distance(from: far.centre, to: ahead) < 1)
        #expect(abs(far.radius - 60_000) < 1)
    }
}

struct GroundEstimateTests {
    private func tile(at coordinate: GeoCoordinate, radius: Double, minimum: Double) -> TileHeightRange {
        TileHeightRange(centre: Geodesy.ecef(coordinate, height: minimum), radius: radius,
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
        let farCentre = GeoMath.destination(from: sanFrancisco, bearing: 2, distance: 50_000)
        let far = tile(at: farCentre, radius: 100, minimum: 30)
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
        let camera = EyeLevelModel.framePlace(centre: sanFrancisco, radius: 600, heading: 0.5, room: volume)
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

    @Test func statesOfOtherVersionsAreRejected() {
        #expect(throws: MapViewState.ParseError.unsupportedVersion) { try MapViewState.parse(#"{"version":1}"#) }
        #expect(throws: MapViewState.ParseError.notAViewState) { try MapViewState.parse(#"{"radius":600}"#) }
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
