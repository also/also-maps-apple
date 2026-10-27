import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

/// The volume's geometry, as MapPresentation.volume defines it.
private let volume = RoomGeometry(designEye: SIMD3(0, 0.3, 0.85),
                                  placementLevel: SIMD3(0, -0.25, 0),
                                  placementDown: SIMD3(0, 0, 0),
                                  contentHalfWidth: 0.5)
private let immersive5 = RoomGeometry(designEye: SIMD3(0, 1.6, 0),
                                  placementLevel: SIMD3(0, 0.02, -3.1),
                                  placementDown: SIMD3(0, 1.3, -3.1),
                                  contentHalfWidth: 2.5)
private let sanFrancisco = GeoCoordinate(latitude: 37.7955, longitude: -122.3937)
private let context = NavigationContext(cameraGround: 0, minimumAltitude: 55, maximumAltitude: 20_000_000)

private func framing(_ camera: CameraPose, _ room: RoomGeometry = volume) throws -> AdaptiveModel.Framing {
    try #require(AdaptiveModel.framing(camera: camera, room: room, rayHeight: 0, envelopeHeight: 0))
}

struct PlaceFramingTests {
    @Test(arguments: [600.0, 8_000, 200_000])
    func placeCentreLandsOnTheTableAtTheRequestedScale(radius: Double) throws {
        let camera = AdaptiveModel.framePlace(centre: sanFrancisco, radius: radius, heading: 0.3, room: volume)
        let f = try framing(camera)
        let centre = Geodesy.ecef(sanFrancisco, height: 0)
        #expect(simd_distance(f.georeference.map(centre), f.placementPoint) < 1e-3)
        #expect(abs(f.shownRadius(volume) / radius - 1) < 0.01)
    }
}

struct AnchoredManipulationTests {
    private func solve(grabAt p: SIMD3<Double>, to target: SIMD3<Double>, magnification: Double,
                       twist: Double, room: RoomGeometry = volume) throws -> (AdaptiveModel.Framing, SIMD3<Double>, Double) {
        // Framed in the same room, so the map starts level on its surface.
        let start = AdaptiveModel.framePlace(centre: sanFrancisco, radius: 600, heading: 0.2, room: room)
        let before = try framing(start, room)
        let grab = before.georeference.ecef(map: p)
        let anchor = AdaptiveModel.AnchorTarget(
            grab: grab, target: target, scale: before.georeference.scale * magnification,
            heading: start.heading + twist, headingOrigin: start.coordinate,
            pitch: { AdaptiveModel.pitchTarget(altitude: $0, levelPitch: room.levelPitch) })
        let solution = AdaptiveModel.solve(anchor, from: start, room: room, rayHeight: 0, envelopeHeight: 0,
                                           context: context)
        let after = try framing(solution.pose, room)
        return (after, grab, before.georeference.scale * magnification)
    }

    @Test(arguments: [0.5, 2.0, 5.0])
    func pinchKeepsTheGrabbedPointUnderTheHand(magnification: Double) throws {
        let p = SIMD3(0.2, -0.25, 0.15)
        let (after, grab, scale) = try solve(grabAt: p, to: p, magnification: magnification, twist: 0)
        #expect(simd_distance(after.georeference.map(grab), p) < 1e-3)
        #expect(abs(after.georeference.scale / scale - 1) < 1e-3)
    }

    @Test func pinchTwistAndDragTogether() throws {
        let p = SIMD3(-0.1, -0.25, 0.2)
        let target = p + SIMD3(0.05, 0, -0.08)
        let (after, grab, scale) = try solve(grabAt: p, to: target, magnification: 1.7, twist: 40 * degrees)
        #expect(simd_distance(after.georeference.map(grab), target) < 1e-3)
        #expect(abs(after.georeference.scale / scale - 1) < 1e-3)
    }

    /// Gestures arrive in the reference space and pass through the room
    /// placement first; the solve then holds in the map frame, so the grab
    /// stays under the hand in the room too.
    @Test func holdsAfterANonIdentityRoomPlacement() throws {
        let placement = RoomPlacement(translation: SIMD3(0.3, 0, -0.4), yaw: 0.6)
        // On the base plane, where the gesture slab is.
        let handInRoom = SIMD3(0.5, 0.02, -2.6)
        let p = placement.similarity.inverse.apply(handInRoom)
        let (after, grab, _) = try solve(grabAt: p, to: p, magnification: 2, twist: 0.3, room: immersive5)
        #expect(simd_distance(placement.similarity.apply(after.georeference.map(grab)), handInRoom) < 1e-3)
    }
}

struct ContinuityTests {
    /// Straight ascent with the pitch assist: the georeference changes by a
    /// bounded step per frame, with no jumps, from the city to orbit.
    @Test func ascentIsContinuous() throws {
        let flight = ModelFlightStyle()
        var state = flight.activate(NavigationState(
            camera: AdaptiveModel.framePlace(centre: sanFrancisco, radius: 600, heading: 0, room: volume)))
        let dt = 1.0 / 90
        var previous = try framing(state.camera)
        var largestScaleStep = 0.0, largestMove = 0.0
        for _ in 0..<(90 * 12) {
            state = flight.step(state, input: ControlInput(climb: 1), deltaTime: dt, context: context)
            let target = AdaptiveModel.pitchTarget(altitude: state.camera.height, levelPitch: volume.levelPitch)
            state.camera.pitch += (target - state.camera.pitch) * min(1, dt * 6)
            state.camera.pitch = min(state.camera.pitch,
                                     AdaptiveModel.pitchLimit(cameraHeight: state.camera.height, rayHeight: 0,
                                                              latitude: state.camera.latitude))
            let current = try framing(state.camera)
            largestScaleStep = max(largestScaleStep, abs(log(current.georeference.scale / previous.georeference.scale)))
            // How far a point under the placement point moves in the room.
            let probe = previous.georeferencePoint
            largestMove = max(largestMove, simd_distance(current.georeference.map(probe),
                                                         previous.georeference.map(probe)))
            previous = current
        }
        // Climbing at e¹ per second scales by at most e^(1/90) per frame.
        #expect(largestScaleStep < 1.0 / 90 * 1.05)
        #expect(largestMove < 0.02)
        #expect(state.camera.height > 100_000)
    }

    @Test func pitchTargetIsInsideTheHorizonLimit() {
        for altitude in stride(from: 100.0, to: 5_000_000, by: 7_919) {
            let target = AdaptiveModel.pitchTarget(altitude: altitude, levelPitch: immersive5.levelPitch)
            let limit = AdaptiveModel.pitchLimit(cameraHeight: altitude, rayHeight: 0, latitude: 0)
            #expect(target <= limit)
        }
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
        let camera = AdaptiveModel.framePlace(centre: sanFrancisco, radius: 600, heading: 0.5, room: volume)
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
        let legacy = #"{"flyScale":1,"flying":false,"focusHeight":-32,"headingDegrees":25,"latitude":37.7955,"longitude":-122.3937,"presentation":"volume","radius":600}"#
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
