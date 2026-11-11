import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

/// Immersive 10×, as MapPresentation defines it.
private let immersive = RoomGeometry(designEye: SIMD3(0, 1.6, 0),
                                     placementLevel: SIMD3(0, 0.02, -5.6),
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
    func noTiltBelowFiftyKilometers(altitude: Double) {
        #expect(EyeLevelModel.tiltWeight(altitude: altitude) == 0)
    }

    @Test(arguments: [0.0, 0.4, 1])
    func theCameraStaysOnTheEyeAtAnyTilt(weight: Double) {
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 600_000,
                                heading: 0.5, pitch: -0.3)
        let f = framing(camera, weight: weight)
        #expect(simd_distance(f.georeference.map(camera.position), immersive.designEye) < 1e-6)
    }

    @Test
    func tiltFacesTheViewerFarOut() {
        #expect(EyeLevelModel.tiltWeight(altitude: 600_000) == 1)
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 600_000,
                                heading: 0, pitch: -0.3)
        let f = framing(camera, weight: 1)
        // The ground beneath the camera is straight ahead, as far as the base
        // plane is below the eye, and the local up there points back at the
        // viewer.
        let nadir = Geodesy.ecef(ronda, height: 565)
        #expect(simd_distance(f.georeference.map(nadir), immersive.designEye - SIMD3(0, 0, 1.58)) < 1e-6)
        let up = Geodesy.enu(latitude: ronda.latitude, longitude: ronda.longitude).up
        #expect(simd_distance(simd_normalize(f.georeference.rotation.act(up)), SIMD3(0, 0, 1)) < 1e-9)
    }

    @Test(arguments: [1_510.0, 100_000, 158_000, 300_000, 600_000, 5_000_000])
    func theViewCenterIsOnTheLineOfSight(altitude: Double) {
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: altitude,
                                heading: 0.5, pitch: -0.3)
        let w = EyeLevelModel.tiltWeight(for: camera)
        let f = framing(camera, weight: w)
        // On the ground, in front of the viewer: the line of sight meets the
        // globe rather than falling back to the ground below.
        let sight = immersive.sightLine(tiltWeight: w)
        let toPlaced = f.placementPoint - immersive.designEye
        #expect(simd_length(simd_cross(sight, simd_normalize(toPlaced))) < 1e-6)
        #expect(simd_dot(sight, toPlaced) > 0)
        #expect(abs(Geodesy.geodetic(f.georeferencePoint).height - 565) < 1e-3)
    }

    @Test(arguments: [0.0, 0.25, 0.5, 0.75, 1])
    func theLineOfSightTurnsFromC0ToStraightAhead(weight: Double) {
        let sight = immersive.sightLine(tiltWeight: weight)
        let level = atan2(1.58, 5.6)
        #expect(abs(asin(-sight.y) - level * (1 - weight)) < 1e-12)
        #expect(abs(sight.x) < 1e-12 && sight.z < 0)
    }

    @Test
    func theViewCenterIsTheGroundBelowAtFullTilt() {
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 600_000,
                                heading: 0.5, pitch: -0.3)
        let f = framing(camera, weight: 1)
        #expect(simd_distance(f.georeferencePoint, Geodesy.ecef(ronda, height: 565)) < 1e-3)
    }

    @Test(arguments: [600.0, 8_000, 30_000])
    func placeCenterLandsOnTheMapCenterAtTheRequestedScale(radius: Double) {
        let camera = EyeLevelModel.framePlace(center: ronda, radius: radius, heading: 0.3,
                                              room: immersive, groundHeight: 565)
        let f = framing(camera)
        let center = Geodesy.ecef(ronda, height: 565)
        // On the view center: where the line of sight to C₀ meets the
        // ground, a little past C₀ for the Earth's curve.
        let landed = f.georeference.map(center)
        #expect(simd_distance(landed, f.placementPoint) < 1e-3)
        #expect(simd_distance(landed, immersive.placementLevel) < 0.1)
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
        let start = EyeLevelModel.framePlace(center: ronda, radius: 3_000, heading: 0.2,
                                             room: immersive, groundHeight: 565)
        let before = framing(start)
        let p = SIMD3(0.4, 0.02, -3.0)
        let grab = before.georeference.ecef(map: p)
        let height = 565 + EyeLevelModel.altitude(forScale: before.georeference.scale * 2, room: immersive)
        let pose = AdaptiveModel.pose(for: AdaptiveModel.Grab(point: grab, start: p,
                                                              startRotation: before.georeference.rotation,
                                                              twist: 0.3),
                                      height: height, from: start) { framing($0) }
        let after = framing(pose)
        #expect(simd_distance(after.georeference.map(grab), p) < 1e-3)
        #expect(abs(after.georeference.scale / (before.georeference.scale * 2) - 1) < 1e-9)
    }
}
