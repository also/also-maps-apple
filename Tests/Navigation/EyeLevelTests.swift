import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

/// Immersive 10×, as MapPresentation defines it.
private let immersive = RoomGeometry(designEye: SIMD3(0, 1.6, 0),
                                     placementLevel: SIMD3(0, 0.02, -5.6),
                                     contentHalfWidth: 5,
                                     restingDip: 15 * .pi / 180)
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
    func theTiltTurnsTheNavigationPositionAboutThePivot(weight: Double) {
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 600_000,
                                heading: 0.5, pitch: -0.3)
        let f = framing(camera, weight: weight)
        let pivot = immersive.tiltPivot
        let turned = pivot + simd_quatd(angle: weight * immersive.fullTilt, axis: SIMD3(1, 0, 0))
            .act(immersive.designEye - pivot)
        #expect(simd_distance(f.georeference.map(camera.position), turned) < 1e-6)
    }

    @Test
    func tiltFacesTheViewerFarOut() {
        #expect(EyeLevelModel.tiltWeight(altitude: 600_000) == 1)
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 600_000,
                                heading: 0, pitch: -0.3)
        let f = framing(camera, weight: 1)
        // The ground beneath the navigation position is straight ahead, as
        // far as the level view center is from the eye, and the local up
        // there points back at the viewer.
        let nadir = Geodesy.ecef(ronda, height: 565)
        let reach = immersive.levelReach
        #expect(abs(reach - 1.58 / sin(15 * degrees)) < 1e-12)
        #expect(simd_distance(f.georeference.map(nadir), immersive.designEye - SIMD3(0, 0, reach)) < 1e-6)
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
    func theLineOfSightTurnsFromTheRestingDipToStraightAhead(weight: Double) {
        let sight = immersive.sightLine(tiltWeight: weight)
        let level = 15 * degrees
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
        // On the view center: where the resting line of sight meets the
        // ground, a little past where it meets the base plane for the
        // Earth's curve.
        let landed = f.georeference.map(center)
        #expect(simd_distance(landed, f.placementPoint) < 1e-3)
        #expect(simd_distance(landed, immersive.levelViewCenter) < 0.1)
        #expect(abs(f.shownRadius(immersive) / radius - 1) < 0.01)
    }

    @Test
    func humanScaleKeepsTheGroundAtItsRealDistance() {
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 1_510,
                                heading: 0.7, pitch: -0.4)
        let f = EyeLevelModel.framing(camera: camera, room: immersive, groundHeight: 565, tiltWeight: 0,
                                      fixedScale: 1)
        #expect(f.georeference.scale == 1)
        #expect(simd_distance(f.georeference.map(camera.position), immersive.designEye) < 1e-6)
        let nadir = Geodesy.ecef(ronda, height: 565)
        #expect(simd_distance(f.georeference.map(nadir), immersive.designEye - SIMD3(0, 945, 0)) < 1e-6)
        // Fully tilted, the ground below faces the eye, turned about the
        // pivot.
        let tilted = EyeLevelModel.framing(camera: camera, room: immersive, groundHeight: 565, tiltWeight: 1,
                                           fixedScale: 1)
        let pivot = immersive.tiltPivot(groundBelow: 945)
        let below = immersive.designEye - SIMD3(0, 945, 0)
        let turned = pivot + simd_quatd(angle: immersive.fullTilt, axis: SIMD3(1, 0, 0)).act(below - pivot)
        #expect(simd_distance(tilted.georeference.map(nadir), turned) < 1e-6)
    }

    /// Turning human scale on or off changes only the scale, about the eye,
    /// so the picture from the eye stays the same at any tilt: everything
    /// keeps its direction, nearer or farther by the same factor.
    @Test(arguments: [0.0, 0.5, 1])
    func humanScaleLeavesThePictureFromTheEye(weight: Double) {
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 300_000,
                                heading: 0.7, pitch: -0.4)
        let model = framing(camera, weight: weight)
        let human = EyeLevelModel.framing(camera: camera, room: immersive, groundHeight: 565, tiltWeight: weight,
                                          fixedScale: 1)
        let eye = immersive.designEye
        let points = [Geodesy.ecef(ronda, height: 565),
                      Geodesy.ecef(GeoCoordinate(latitude: 37.5, longitude: -4.2), height: 0),
                      Geodesy.ecef(GeoCoordinate(latitude: 35.0, longitude: -6.5), height: 2_000)]
        for point in points {
            let a = model.georeference.map(point) - eye, b = human.georeference.map(point) - eye
            #expect(simd_distance(simd_normalize(a), simd_normalize(b)) < 1e-9)
            #expect(abs(simd_length(b) / simd_length(a) * model.georeference.scale - 1) < 1e-9)
        }
    }

    @Test
    func pinchKeepsTheGrabbedPointWhereItWas() {
        let start = EyeLevelModel.framePlace(center: ronda, radius: 3_000, heading: 0.2,
                                             room: immersive, groundHeight: 565)
        let before = framing(start)
        // As the app grabs: the gaze hit put on the ground.
        let grab = GestureSurface.snap(before.georeference.ecef(map: SIMD3(0.4, 0.02, -3.0)), toHeight: 565)
        let p = before.georeference.map(grab)
        let height = 565 + EyeLevelModel.altitude(forScale: before.georeference.scale * 2, room: immersive)
        let pose = AdaptiveModel.pose(for: AdaptiveModel.Grab(point: grab, start: p,
                                                              startRotation: before.georeference.rotation, startCamera: start,
                                                              twist: 0.3),
                                      height: height, from: start, room: immersive) { framing($0) }
        let after = framing(pose)
        #expect(simd_distance(after.georeference.map(grab), p) < 1e-3)
        #expect(abs(after.georeference.scale / (before.georeference.scale * 2) - 1) < 1e-9)
    }

    // MARK: The resting dip and the horizon margin

    /// The volume, as MapPresentation defines it: its line of sight is
    /// toward C₀, about 33° below level.
    private static let volume: RoomGeometry = {
        let eye = SIMD3<Double>(0, 0.3, 0.85)
        return RoomGeometry(designEye: eye, placementLevel: SIMD3(0, -0.25, 0), contentHalfWidth: 0.5,
                            fullTilt: RoomGeometry.tiltFacing(.zero, from: eye))
    }()

    /// How far below the horizon, seen from the eye's place in the world,
    /// the view center is, and how far around the globe from the navigation
    /// position, radians.
    private static func viewCenter(_ room: RoomGeometry, altitude: Double) -> (belowHorizon: Double, around: Double,
                                                                              framing: AdaptiveModel.Framing) {
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: altitude + 565,
                                heading: 0.5, pitch: -0.3)
        let f = EyeLevelModel.framing(camera: camera, room: room, groundHeight: 565, tiltWeight: 0)
        let eye = f.georeference.ecef(map: room.designEye)
        let up = simd_normalize(eye)
        let dip = asin(-simd_dot(simd_normalize(f.georeferencePoint - eye), up))
        let horizon = acos((simd_length(eye) - altitude) / simd_length(eye))
        let around = acos(min(simd_dot(simd_normalize(f.georeferencePoint), simd_normalize(camera.position)), 1))
        return (dip - horizon, around, f)
    }

    @Test(arguments: [1.2, 1.6, 1.9])
    func theRestingDipPutsTheViewCenterTheSameDistanceAheadForAnyEyeHeight(eyeHeight: Double) {
        var room = immersive
        room.designEye.y = eyeHeight
        let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 1_510,
                                heading: 0.5, pitch: -0.3)
        let f = EyeLevelModel.framing(camera: camera, room: room, groundHeight: 565, tiltWeight: 0)
        let ahead = GeoMath.distance(from: ronda, to: Geodesy.geodetic(f.georeferencePoint).coordinate)
        // 945 m up, 15° down: 945 / tan 15°, within the Earth's curve and
        // the distance's spherical estimate. The same point as for the
        // 1.6 m eye.
        #expect(abs(ahead / (945 / tan(15 * degrees)) - 1) < 0.005)
        #expect(simd_distance(f.georeferencePoint, framing(camera).georeferencePoint) < 1e-3)
        #expect(abs(simd_distance(f.placementPoint, room.designEye) - room.levelReach) < 0.01)
    }

    @Test
    func aHostWithoutARestingDipLooksAtC0() {
        let room = Self.volume
        #expect(abs(room.levelDip - atan2(0.55, 0.85)) < 1e-12)
        #expect(room.levelViewCenter == room.placementLevel)
        #expect(simd_distance(room.sightLine(tiltWeight: 0), simd_normalize(room.placementLevel - room.designEye)) < 1e-12)
    }

    @Test(arguments: [immersive, Self.volume])
    func lowDownTheHorizonMarginChangesNothing(room: RoomGeometry) {
        // The immersive space's 15° comes within 5° of the horizon at about
        // 100 km; the volume's 33° at about 850 km.
        for altitude in [1_000.0, 20_000, 80_000] {
            let (belowHorizon, _, f) = Self.viewCenter(room, altitude: altitude)
            #expect(belowHorizon > EyeLevelModel.horizonMargin)
            let toPlaced = simd_normalize(f.placementPoint - room.designEye)
            #expect(simd_distance(toPlaced, room.sightLine(tiltWeight: 0)) < 1e-9)
        }
    }

    @Test(arguments: [immersive, Self.volume])
    func withNoTiltTheViewCenterStaysOnTheGlobeAtAnyHeightWithoutAJump(room: RoomGeometry) {
        var last: (around: Double, placed: SIMD3<Double>)?
        var altitude = 1_000.0
        while altitude < 11_000_000 {
            let (belowHorizon, around, f) = Self.viewCenter(room, altitude: altitude)
            // On the ground, ahead, and clear of the horizon.
            #expect(abs(Geodesy.geodetic(f.georeferencePoint).height - 565) < 1e-2)
            #expect(belowHorizon > EyeLevelModel.horizonMargin - 0.2 * degrees)
            #expect(f.placementPoint.z < room.designEye.z)
            #expect(around > 0)
            if let last {
                // 1% higher moves the view center a little: no jump, in the
                // world or in the room.
                #expect(abs(around - last.around) < 0.02 * max(around, last.around) + 1e-9)
                let reach = simd_distance(f.placementPoint, room.designEye)
                #expect(simd_distance(f.placementPoint, last.placed) < 0.02 * reach)
            }
            last = (around, f.placementPoint)
            altitude *= 1.01
        }
    }

    @Test
    func highUpWithNoTiltTheLineFollowsTheHorizonDown() {
        // 300 km: the horizon is 17° down, past the resting 15°. The line is
        // 5° below it, not on the ground below the navigation position.
        let (belowHorizon, around, _) = Self.viewCenter(immersive, altitude: 300_000)
        #expect(abs(belowHorizon - EyeLevelModel.horizonMargin) < 0.2 * degrees)
        #expect(around * GeoMath.earthRadius > 500_000)
    }
}
