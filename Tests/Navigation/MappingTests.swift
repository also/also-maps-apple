import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

struct StreamingInputsTests {
    @Test func orbitCameraMatchesTheBridgeFormula() {
        let lod = LODCamera.orbit(heading: 0, elevation: .pi / 4, distance: 1200)
        let h = 0.5.squareRoot()
        #expect(simd_distance(lod.direction, SIMD3(0, -h, -h)) < 1e-12)
        #expect(simd_distance(lod.up, SIMD3(0, h, -h)) < 1e-12)
        #expect(simd_distance(lod.position, SIMD3(0, 1200 * h, 1200 * h)) < 1e-9)
    }

    @Test(arguments: [0.0, 1.0, 3 * Double.pi / 2])
    func orbitVectorsAreOrthonormalAtAnyElevation(heading: Double) {
        for elevation in [0.0, 0.3, Double.pi / 4, Double.pi / 2, 2.0] {
            let lod = LODCamera.orbit(heading: heading, elevation: elevation, distance: 500)
            #expect(abs(simd_length(lod.direction) - 1) < 1e-12)
            #expect(abs(simd_length(lod.up) - 1) < 1e-12)
            #expect(abs(simd_dot(lod.direction, lod.up)) < 1e-12)
            #expect(abs(simd_length(lod.position) - 500) < 1e-9)
        }
    }
}

struct GeoreferenceTests {
    /// Tiles placed relative to a different (held) anchor land in the same
    /// place: the root follows whatever anchor the streamer is on.
    @Test func placementFollowsWhicheverAnchorTheStreamerUses() {
        let room = RoomGeometry(designEye: SIMD3(0, 0.3, 0.85),
                                placementLevel: SIMD3(0, -0.25, 0),
                                contentHalfWidth: 0.5)
        let camera = CameraPose(latitude: 37.7955, longitude: -122.3937, height: 600,
                                heading: 25 * degrees, pitch: 0)
        let georeference = EyeLevelModel.framing(camera: camera, room: room,
                                                 groundHeight: -32, tiltWeight: 0).georeference
        let held = StreamingAnchor(coordinate: GeoCoordinate(latitude: 37.80, longitude: -122.40), height: 10)
        let world = Geodesy.ecef(latitude: 37.7962, longitude: -122.3951, height: 25)
        let local = held.ecefFromAnchor.inverse.apply(world)
        #expect(simd_distance(georeference.placement(of: held).apply(local), georeference.map(world)) < 1e-9)
    }
}

struct AdaptiveModelTests {
    @Test(arguments: [(24_000.0, -13.0), (98_000.0, -18.0), (410_000.0, -28.0), (2_600_000.0, -53.0)])
    func pitchLimitKeepsTheMarginBelowTheHorizon(height: Double, limitDegrees: Double) {
        let limit = AdaptiveModel.pitchLimit(cameraHeight: height, rayHeight: 0, latitude: 0)
        #expect(abs(limit / degrees - limitDegrees) < 0.3)
        // Rays at the limit hit.
        let camera = CameraPose(latitude: 0, longitude: 0, height: height, heading: 0, pitch: limit)
        guard case .hit = Geodesy.intersect(ray: Ray(origin: camera.position, direction: camera.basis.forward),
                                            surfaceHeight: 0) else {
            Issue.record("expected a hit at the limit"); return
        }
    }

    @Test func pitchLimitAtOrBelowTheSurfaceIsJustTheMargin() {
        #expect(AdaptiveModel.pitchLimit(cameraHeight: 5, rayHeight: 10, latitude: 0) == -8 * degrees)
        #expect(AdaptiveModel.pitchLimit(cameraHeight: .nan, rayHeight: 0, latitude: 0) == -8 * degrees)
    }
}
