import Foundation
import simd
import Testing

private let degrees = Double.pi / 180
private let ronda = GeoCoordinate(latitude: 36.7377, longitude: -5.1728)

struct ScreenViewTests {
    private let camera = CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: 1_510,
                                    heading: 60 * degrees, pitch: -25 * degrees)

    @Test
    func theCameraIsAtTheOriginLookingDownItsMinusZ() {
        let georeference = ScreenView.georeference(camera: camera)
        #expect(simd_length(georeference.map(camera.position)) < 1e-6)
        #expect(georeference.scale == 1)
        let orientation = ScreenView.cameraOrientation(camera: camera)
        let basis = camera.basis
        #expect(simd_distance(orientation.act(SIMD3(0, 0, -1)), georeference.rotation.act(basis.forward)) < 1e-9)
        #expect(simd_distance(orientation.act(SIMD3(0, 1, 0)), georeference.rotation.act(basis.up)) < 1e-9)
    }

    @Test
    func theSceneIsLevelAtTheCamera() {
        let up = Geodesy.enu(latitude: ronda.latitude, longitude: ronda.longitude).up
        #expect(simd_distance(ScreenView.georeference(camera: camera).rotation.act(up), SIMD3(0, 1, 0)) < 1e-9)
    }

    @Test
    func levelOfDetailIsChosenForTheCameraItself() {
        let inputs = ScreenView.streamingInputs(camera: camera, groundHeight: 565,
                                                fieldOfView: .pi / 4, aspect: 1.5)
        let toECEF = inputs.anchor.ecefFromAnchor
        #expect(simd_distance(toECEF.apply(inputs.lod.position), camera.position) < 1e-6)
        #expect(simd_distance(toECEF.rotation.act(inputs.lod.direction), camera.basis.forward) < 1e-9)
        #expect(inputs.lod.aspect == 1.5)
        // Everything visible, out past the horizon from 945 m up.
        #expect(inputs.streamingRadius > (2 * GeoMath.earthRadius * 945).squareRoot())
        #expect(inputs.anchor.height == 565)
    }

    @Test(arguments: [200.0, 3_000, 40_000])
    func aPlaceIsCentredInView(radius: Double) {
        let pose = ScreenView.framePlace(centre: ronda, radius: radius, heading: 0.3, groundHeight: 565)
        let centre = Geodesy.ecef(ronda, height: 565)
        let toCentre = simd_normalize(centre - pose.position)
        #expect(simd_distance(toCentre, pose.basis.forward) < 1e-6)
        #expect(abs(simd_distance(centre, pose.position) - radius / tan(Double.pi / 8)) < 1e-3 * radius)
        // Looking down at the centre by the place elevation; at the camera,
        // less by the Earth's curve between them.
        let elevation = ScreenView.placeElevation
        let curve = simd_distance(centre, pose.position) * cos(elevation) / GeoMath.earthRadius
        #expect(abs(pose.pitch + elevation) < curve + 1e-3)
    }

    @Test
    func aStaticViewsCameraRoundTripsThroughTheScreenView() {
        let view = StaticView.ferry
        let pose = view.cameraPose
        let inputs = ScreenView.streamingInputs(camera: pose, groundHeight: 0, fieldOfView: .pi / 3, aspect: 1)
        let original = view.inputs.anchor.ecefFromAnchor
        #expect(simd_distance(inputs.anchor.ecefFromAnchor.apply(inputs.lod.position),
                              original.apply(view.inputs.lod.position)) < 1e-6)
        #expect(simd_distance(inputs.anchor.ecefFromAnchor.rotation.act(inputs.lod.direction),
                              original.rotation.act(view.inputs.lod.direction)) < 1e-9)
    }

    @Test
    func lookingUpAndDownPitchesTheCamera() {
        let flight = ModelFlightStyle()
        var input = ControlInput()
        input.pitch = 1
        let state = flight.step(NavigationState(camera: camera), input: input, deltaTime: 0.5,
                                context: NavigationContext(cameraGround: 565))
        #expect(abs(state.camera.pitch - (camera.pitch + flight.pitchRate * 0.5)) < 1e-12)
        #expect(state.camera.position == camera.position)
    }
}
