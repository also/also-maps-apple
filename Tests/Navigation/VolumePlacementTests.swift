import Foundation
import simd
import Testing

/// Stage 2b: the volume placed like the immersive space (docs/camera-core.md
/// §5), with its tilt a function of where the camera is.

private let degrees = Double.pi / 180

/// As MapPresentation defines them.
private let volume = RoomGeometry(designEye: SIMD3(0, 0.3, 0.85),
                                  placementLevel: SIMD3(0, -0.25, 0),
                                  placementDown: SIMD3(0, 0, 0),
                                  contentHalfWidth: 0.5,
                                  fullTilt: RoomGeometry.tiltFacing(SIMD3(0, 0, 0), from: SIMD3(0, 0.3, 0.85)),
                                  viewCentreFollowsTilt: true)
private let immersive = RoomGeometry(designEye: SIMD3(0, 1.6, 0),
                                     placementLevel: SIMD3(0, 0.02, -5.6),
                                     placementDown: SIMD3(0, 1.3, -5.6),
                                     contentHalfWidth: 5)
/// The volume's box: 1 × 0.6 × 1 m about its centre.
private let boxHalfSize = SIMD3(0.5, 0.3, 0.5)

private let places = [
    GeoCoordinate(latitude: 37.7955, longitude: -122.3937),
    GeoCoordinate(latitude: -33.86, longitude: 151.21),
    GeoCoordinate(latitude: 78.2, longitude: 15.6),
]

private func framing(_ camera: CameraPose, _ room: RoomGeometry, ground: Double = 0,
                     assist: Bool = true) -> AdaptiveModel.Framing {
    EyeLevelModel.framing(camera: camera, room: room, groundHeight: ground,
                          tiltWeight: assist ? EyeLevelModel.tiltWeight(for: camera) : 0)
}

/// The room's up for the local up beneath `camera`.
private func shownUp(_ f: AdaptiveModel.Framing, _ camera: CameraPose) -> SIMD3<Double> {
    let up = Geodesy.enu(latitude: camera.latitude, longitude: camera.longitude).up
    return simd_normalize(f.georeference.rotation.act(up))
}

struct VolumePlacementTests {
    @Test(arguments: [100.0, 3_000, 45_000, 900_000, 11_000_000])
    func untiltedIsExactlyLevelInEveryHostWhateverThePitch(height: Double) {
        for place in places {
            for pitch in [-89.0, -33, 0, 25] {
                let camera = CameraPose(latitude: place.latitude, longitude: place.longitude, height: height,
                                        heading: 1.1, pitch: pitch * degrees)
                for room in [volume, immersive] {
                    let f = framing(camera, room, assist: false)
                    #expect(simd_distance(shownUp(f, camera), SIMD3(0, 1, 0)) < 1e-12)
                }
            }
        }
    }

    @Test(arguments: [100.0, 3_000, 45_000])
    func belowFiftyKilometresTheAssistLeavesItLevel(height: Double) {
        let camera = CameraPose(latitude: 37.79, longitude: -122.39, height: height, heading: 0.3, pitch: -0.4)
        #expect(EyeLevelModel.tiltWeight(for: camera) == 0)
        #expect(simd_distance(shownUp(framing(camera, volume), camera), SIMD3(0, 1, 0)) < 1e-12)
    }

    @Test(arguments: [600.0, 120_000, 900_000])
    func pitchDoesNotMoveTheVolume(height: Double) {
        var camera = CameraPose(latitude: 37.79, longitude: -122.39, height: height, heading: 0.3, pitch: -0.2)
        let a = framing(camera, volume)
        for pitch in [-89.0, -50, 0, 30] {
            camera.pitch = pitch * degrees
            let b = framing(camera, volume)
            #expect(b.georeference == a.georeference)
            #expect(b.georeferencePoint == a.georeferencePoint)
        }
    }

    /// The tilt depends only on where the camera is: a new ground estimate
    /// rescales the map but doesn't turn it.
    @Test(arguments: [600.0, 120_000, 900_000])
    func tiltIgnoresTheGroundEstimate(height: Double) {
        let camera = CameraPose(latitude: 50.5, longitude: -88.5, height: height, heading: 2.7, pitch: -1.5)
        let a = framing(camera, volume, ground: -50)
        let b = framing(camera, volume, ground: -20_800)
        #expect(simd_distance(shownUp(a, camera), shownUp(b, camera)) < 1e-12)
    }

    /// Switching host keeps the camera; untilted, both hosts are level, and
    /// tilted, both turn by the same weight of their own full tilt.
    @Test(arguments: [600.0, 120_000, 900_000])
    func hostSwitchKeepsTheTiltWeight(height: Double) {
        let camera = CameraPose(latitude: 37.79, longitude: -122.39, height: height, heading: 0.3, pitch: -0.4)
        let w = EyeLevelModel.tiltWeight(for: camera)
        for room in [volume, immersive] {
            let up = shownUp(framing(camera, room), camera)
            // Tilting toward the viewer turns up toward +z.
            let angle = atan2(up.z, up.y)
            #expect(abs(angle - w * room.fullTilt) < 1e-9)
            #expect(abs(up.x) < 1e-12)
        }
    }

    @Test(arguments: [600.0, 120_000, 900_000, 11_000_000])
    func theCameraStaysOnTheEyeAtAnyTilt(height: Double) {
        let camera = CameraPose(latitude: -33.86, longitude: 151.21, height: height, heading: 4, pitch: -0.4)
        let f = framing(camera, volume)
        #expect(simd_distance(f.georeference.map(camera.position), volume.designEye) < 1e-6)
    }

    /// Fully tilted, the ground below faces you along your line of sight to
    /// the box's centre, as far from the eye as the base plane is below it.
    @Test func fullTiltFacesTheViewerAtTheBoxCentre() {
        let camera = CameraPose(latitude: 37.79, longitude: -122.39, height: 900_000, heading: 0.3, pitch: -0.4)
        #expect(EyeLevelModel.tiltWeight(for: camera) == 1)
        let f = framing(camera, volume, ground: 10)
        let nadir = Geodesy.ecef(camera.coordinate, height: 10)
        let towardCentre = simd_normalize(volume.placementDown - volume.designEye)
        #expect(simd_distance(f.georeference.map(nadir), volume.designEye + 0.55 * towardCentre) < 1e-6)
        #expect(simd_distance(shownUp(f, camera), -towardCentre) < 1e-9)
        // The view centre is the ground below.
        #expect(GeoMath.distance(from: Geodesy.geodetic(f.georeferencePoint).coordinate, to: camera.coordinate) < 1)
    }

    /// The view centre (where the gesture slab goes) stays in the box at
    /// every altitude, on C₀ while level.
    @Test func viewCentreStaysInTheBox() {
        var height = 60.0
        while height < 11_000_000 {
            let camera = CameraPose(latitude: 37.79, longitude: -122.39, height: height, heading: 0.3, pitch: -0.4)
            let f = framing(camera, volume)
            let p = f.placementPoint
            #expect(abs(p.x) <= boxHalfSize.x && abs(p.y) <= boxHalfSize.y && abs(p.z) <= boxHalfSize.z,
                    "view centre at \(p) for \(Int(height)) m")
            if EyeLevelModel.tiltWeight(for: camera) == 0 {
                // On C₀, but for the Earth's curve: the line of sight meets
                // the ground a little past it.
                #expect(simd_distance(SIMD2(p.x, p.z), SIMD2(0, 0)) < 0.01)
            }
            height *= 1.3
        }
    }

    /// While level, no ground you can see falls through the box's floor, up
    /// to where the tilt starts (50 km), with no curvature envelope. (Higher
    /// up the tilted globe is bigger than the box, and the floor cuts it, as
    /// the old placement's did.)
    @Test func visibleGroundStaysAboveTheFloorWhileLevel() {
        var height = 60.0
        while height < 50_000 {
            let camera = CameraPose(latitude: 37.79, longitude: -122.39, height: height, heading: 0.3, pitch: -0.4)
            let f = framing(camera, volume)
            var lowest = Double.infinity
            for bearing in stride(from: 0.0, to: 2 * .pi, by: .pi / 18) {
                for fraction in stride(from: 0.0, through: 1.0, by: 0.02) {
                    // Out to the horizon.
                    let horizon = (2 * Geodesy.semiMajorAxis * height + height * height).squareRoot()
                    let point = GeoMath.destination(from: camera.coordinate, bearing: bearing,
                                                    distance: fraction * min(horizon, 10_000_000))
                    let ground = Geodesy.ecef(point, height: 0)
                    let up = Geodesy.enu(latitude: point.latitude, longitude: point.longitude).up
                    guard simd_dot(camera.position - ground, up) > 0 else { continue }
                    let p = f.georeference.map(ground)
                    guard abs(p.x) <= boxHalfSize.x, abs(p.z) <= boxHalfSize.z else { continue }
                    lowest = min(lowest, p.y)
                }
            }
            #expect(lowest >= -boxHalfSize.y, "ground at \(lowest) m for \(Int(height)) m")
            height *= 1.3
        }
    }

    /// A place jump frames level (every place in the library is below
    /// 50 km), whatever the camera was before.
    @Test(arguments: [500.0, 8_000, 40_000])
    func placeJumpsAreLevel(radius: Double) {
        for room in [volume, immersive] {
            let camera = EyeLevelModel.framePlace(centre: places[0], radius: radius, heading: 0.7, room: room)
            #expect(simd_distance(shownUp(framing(camera, room), camera), SIMD3(0, 1, 0)) < 1e-12)
        }
    }

    /// Zoom heads for the view centre, wherever the pitch was left pointing,
    /// and leaves the pitch alone.
    @Test func zoomHeadsForTheViewCentre() {
        var flight = ModelFlightStyle()
        let camera = CameraPose(latitude: 37.79, longitude: -122.39, height: 3_000, heading: 0.3, pitch: 20 * degrees)
        let f = framing(camera, volume)
        flight.dollyTarget = f.georeferencePoint
        let context = NavigationContext(cameraGround: 0, minimumAltitude: 55, maximumAltitude: 20_000_000)
        let state = flight.step(NavigationState(camera: camera), input: ControlInput(dolly: 1), deltaTime: 0.1,
                                context: context)
        let moved = state.camera.position - camera.position
        let toCentre = f.georeferencePoint - camera.position
        #expect(simd_length(simd_cross(simd_normalize(moved), simd_normalize(toCentre))) < 1e-6)
        #expect(state.camera.height < camera.height)
        #expect(state.camera.pitch == camera.pitch)
    }

    /// Zooming out into the altitude ceiling stops there rather than
    /// sliding the camera along the globe, in both hosts.
    @Test(arguments: [true, false])
    func zoomStopsAtTheCeiling(inVolume: Bool) {
        let room = inVolume ? volume : immersive
        let context = NavigationContext(cameraGround: 0, minimumAltitude: 55, maximumAltitude: 11_000_000)
        var flight = ModelFlightStyle()
        let start = EyeLevelModel.framePlace(centre: places[0], radius: 600, heading: 0, room: room)
        var state = flight.activate(NavigationState(camera: start))
        var highest = 0.0
        var atCeiling: CameraPose?
        for _ in 0..<(90 * 20) {
            flight.dollyTarget = framing(state.camera, room).georeferencePoint
            state = flight.step(state, input: ControlInput(dolly: -1), deltaTime: 1.0 / 90, context: context)
            highest = max(highest, state.camera.height)
            if atCeiling == nil, state.camera.height > 10_999_000 { atCeiling = state.camera }
        }
        #expect(highest <= 11_000_000 + 1e-6)
        let ceiling = try! #require(atCeiling)
        #expect(GeoMath.distance(from: state.camera.coordinate, to: ceiling.coordinate) < 0.01 * ceiling.height)
        #expect(state.camera.pitch == start.pitch)
    }

    /// With zoom capped where the tilt starts, zooming out to the cap and
    /// back down to the starting height comes back close to where it began:
    /// the view centre within a tenth of the shown half-width (measured:
    /// 11 m in the volume, 50 m in the immersive space, for 600 m).
    @Test(arguments: [true, false])
    func cappedZoomComesBackClose(inVolume: Bool) {
        let room = inVolume ? volume : immersive
        let context = NavigationContext(cameraGround: 0, minimumAltitude: 55, maximumAltitude: 11_000_000)
        var flight = ModelFlightStyle()
        flight.zoomCeiling = EyeLevelModel.tiltStartAltitude
        let start = EyeLevelModel.framePlace(centre: places[0], radius: 600, heading: 0, room: room)
        var state = flight.activate(NavigationState(camera: start))
        func centre() -> SIMD3<Double> { framing(state.camera, room).georeferencePoint }
        let startCentre = centre()
        var highest = 0.0
        func step(_ dolly: Double) {
            flight.dollyTarget = centre()
            state = flight.step(state, input: ControlInput(dolly: dolly), deltaTime: 1.0 / 90, context: context)
            highest = max(highest, state.camera.height)
        }
        for _ in 0..<(90 * 10) { step(-1) }
        // Zooming out stops short of the ceiling, with room to zoom back in.
        #expect(highest <= 0.99 * EyeLevelModel.tiltStartAltitude)
        #expect(highest > 0.98 * EyeLevelModel.tiltStartAltitude)
        #expect(EyeLevelModel.tiltWeight(for: state.camera) == 0)
        let top = state.camera.height
        step(1)
        #expect(state.camera.height < top)
        var frames = 0
        while state.camera.height > start.height, frames < 90 * 30 { step(1); frames += 1 }
        #expect(simd_distance(centre(), startCentre) < 60)
    }

    /// Above the zoom ceiling (climbed to), zoom does nothing either way.
    @Test func aboveTheZoomCeilingZoomDoesNothing() {
        let context = NavigationContext(cameraGround: 0, minimumAltitude: 55, maximumAltitude: 11_000_000)
        var flight = ModelFlightStyle()
        flight.zoomCeiling = EyeLevelModel.tiltStartAltitude
        let camera = CameraPose(latitude: 37.79, longitude: -122.39, height: 200_000, heading: 0.3, pitch: -0.4)
        flight.dollyTarget = framing(camera, volume).georeferencePoint
        let state = NavigationState(camera: camera)
        for dolly in [-1.0, 1.0] {
            let zoomed = flight.step(state, input: ControlInput(dolly: dolly), deltaTime: 0.1, context: context)
            #expect(zoomed.camera == camera)
        }
    }

    /// Holding zoom out at its stop doesn't turn the view: the camera moves
    /// by rounding errors there, which once reversed the heading.
    @Test(arguments: [0.0, 0.3, 2.0])
    func zoomHeldAtTheStopKeepsTheHeading(heading: Double) {
        let context = NavigationContext(cameraGround: -32.5, minimumAltitude: 55, maximumAltitude: 11_000_000)
        var flight = ModelFlightStyle()
        flight.zoomCeiling = EyeLevelModel.tiltStartAltitude
        var state = flight.activate(NavigationState(
            camera: EyeLevelModel.framePlace(centre: places[0], radius: 600, heading: heading, room: volume)))
        var largestTurn = 0.0
        for _ in 0..<(90 * 20) {
            let before = state.camera.heading
            flight.dollyTarget = framing(state.camera, volume, ground: -32.5).georeferencePoint
            state = flight.step(state, input: ControlInput(dolly: -1), deltaTime: 1.0 / 90, context: context)
            largestTurn = max(largestTurn, abs(NavigationOperations.wrapped(state.camera.heading - before)))
        }
        #expect(state.camera.height > 0.98 * EyeLevelModel.tiltStartAltitude)
        #expect(largestTurn < 0.01)
    }

    @Test func bearingChangeIgnoresRoundingNoise() {
        let a = GeoCoordinate(latitude: 37.5, longitude: -122.3)
        let b = GeoCoordinate(latitude: 37.5 + 1e-13, longitude: -122.3 - 1e-13)
        #expect(GeoMath.bearingChange(from: a, to: b) == 0)
    }
}
