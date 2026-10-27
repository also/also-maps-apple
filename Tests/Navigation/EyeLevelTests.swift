import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

/// Immersive 10×, as MapPresentation defines it.
private let immersive = RoomGeometry(designEye: SIMD3(0, 1.6, 0),
                                     placementLevel: SIMD3(0, 0.02, -5.6),
                                     placementDown: SIMD3(0, 1.3, -5.6),
                                     contentHalfWidth: 5)
private let ronda = GeoCoordinate(latitude: 36.7377, longitude: -5.1728)
private let context = NavigationContext(cameraGround: 565, minimumAltitude: 55, maximumAltitude: 20_000_000)

private func framing(_ camera: CameraPose, ground: Double = 565, weight: Double = 0) -> AdaptiveModel.Framing {
    EyeLevelModel.framing(camera: camera, room: immersive, groundHeight: ground, tiltWeight: weight)
}

struct EyeLevelTests {
    @Test(arguments: [-80.0, -15.8, 0, 20])
    func untiltedIsLevelWithTheCameraAtTheEyeWhateverThePitch(pitchDegrees: Double) {
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 1_510,
                                heading: 60 * degrees, pitch: pitchDegrees * degrees)
        let f = framing(camera)
        let up = Geodesy.enu(latitude: ronda.latitude, longitude: ronda.longitude).up
        #expect(simd_distance(simd_normalize(f.georeference.rotation.act(up)), SIMD3(0, 1, 0)) < 1e-9)
        #expect(simd_distance(f.georeference.map(camera.position), immersive.designEye) < 1e-6)
        // The camera's height above the ground is the eye's above the base plane.
        #expect(abs(f.georeference.scale - 1.58 / 945) < 1e-9)
        // Heading faces away from the viewer.
        let forward = camera.basis.forward
        let level = simd_normalize(SIMD3(forward.x, forward.y, forward.z) - simd_dot(forward, up) * up)
        #expect(simd_distance(f.georeference.rotation.act(level), SIMD3(0, 0, -1)) < 1e-9)
    }

    @Test
    func pitchDoesNotMoveTheMap() {
        var camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 1_510,
                                heading: 0.4, pitch: -0.2)
        let a = framing(camera)
        camera.pitch = -1.2
        #expect(framing(camera).georeference == a.georeference)
    }

    @Test(arguments: [100.0, 5_000, 40_000])
    func noTiltBelowFiftyKilometres(altitude: Double) {
        #expect(EyeLevelModel.tiltWeight(altitude: altitude) == 0)
    }

    @Test
    func tiltFacesTheViewerFarOut() {
        #expect(EyeLevelModel.tiltWeight(altitude: 600_000) == 1)
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 600_000,
                                heading: 0, pitch: -0.3)
        let f = framing(camera, weight: 1)
        // The ground beneath the camera is on the raised centre, and the
        // local up there points back at the viewer.
        let nadir = Geodesy.ecef(ronda, height: 565)
        #expect(simd_distance(f.georeference.map(nadir), immersive.placementDown) < 1e-6)
        let up = Geodesy.enu(latitude: ronda.latitude, longitude: ronda.longitude).up
        #expect(simd_distance(simd_normalize(f.georeference.rotation.act(up)), SIMD3(0, 0, 1)) < 1e-9)
    }

    @Test(arguments: [600.0, 8_000, 30_000])
    func placeCentreLandsOnTheMapCentreAtTheRequestedScale(radius: Double) {
        let camera = EyeLevelModel.framePlace(centre: ronda, radius: radius, heading: 0.3,
                                              room: immersive, groundHeight: 565)
        let f = framing(camera)
        let centre = Geodesy.ecef(ronda, height: 565)
        // On C₀ horizontally; below it only by the Earth's curve.
        let landed = f.georeference.map(centre)
        #expect(simd_distance(SIMD2(landed.x, landed.z), SIMD2(0, -5.6)) < 1e-3)
        #expect(abs(landed.y - 0.02) < 0.02)
        #expect(abs(f.shownRadius(immersive) / radius - 1) < 0.01)
    }

    @Test
    func humanScaleKeepsTheCameraOnTheEyeAndTheGroundAtItsRealDistance() {
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 1_510,
                                heading: 0.7, pitch: -0.4)
        let f = EyeLevelModel.framing(camera: camera, room: immersive, groundHeight: 565, tiltWeight: 0,
                                      fixedScale: 1)
        #expect(f.georeference.scale == 1)
        #expect(simd_distance(f.georeference.map(camera.position), immersive.designEye) < 1e-6)
        let nadir = Geodesy.ecef(ronda, height: 565)
        #expect(simd_distance(f.georeference.map(nadir), immersive.designEye - SIMD3(0, 945, 0)) < 1e-6)
        // Fully tilted, the ground below is straight ahead at the same distance.
        let tilted = EyeLevelModel.framing(camera: camera, room: immersive, groundHeight: 565, tiltWeight: 1,
                                           fixedScale: 1)
        #expect(simd_distance(tilted.georeference.map(nadir), immersive.designEye - SIMD3(0, 0, 945)) < 1e-6)
    }

    @Test
    func anchoredPinchKeepsTheGrabUnderTheHand() {
        let start = EyeLevelModel.framePlace(centre: ronda, radius: 3_000, heading: 0.2,
                                             room: immersive, groundHeight: 565)
        let before = framing(start)
        let p = SIMD3(0.4, 0.02, -3.0)
        let grab = before.georeference.ecef(map: p)
        let target = AdaptiveModel.AnchorTarget(grab: grab, target: p, scale: before.georeference.scale * 2,
                                                heading: start.heading + 0.3, headingOrigin: start.coordinate,
                                                pitch: { _ in start.pitch })
        let solution = AdaptiveModel.solve(target, from: start, room: immersive, scaleSurface: 565,
                                           context: context) { framing($0) }
        #expect(solution.error < 1e-3)
        let after = framing(solution.pose)
        #expect(simd_distance(after.georeference.map(grab), p) < 1e-3)
    }
}
