import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

/// The volume and Immersive 5×, as MapPresentation defines them.
private let volume = LegacyMapping.Presentation(isVolume: true, magnification: 1,
                                                groundPosition: SIMD3(0, -0.25, 0),
                                                viewerPosition: SIMD3(0, 0.3, 0.85))
private let immersive5 = LegacyMapping.Presentation(isVolume: false, magnification: 5,
                                                groundPosition: SIMD3(0, 0.02, -3.1),
                                                viewerPosition: SIMD3(0, 1.6, 0))

private func roomGeometry(_ presentation: LegacyMapping.Presentation) -> RoomGeometry {
    let level = presentation.groundPosition
    return RoomGeometry(designEye: presentation.viewerPosition,
                        placementLevel: level,
                        placementDown: SIMD3(level.x, presentation.isVolume ? 0 : presentation.viewerPosition.y - 0.3, level.z),
                        contentHalfWidth: 0.5 * presentation.magnification)
}

private func state(radius: Double, heading: Double = 25 * degrees) -> LegacyMapping.State {
    LegacyMapping.State(focus: GeoCoordinate(latitude: 37.7955, longitude: -122.3937),
                        focusHeight: -32, radius: radius, heading: heading)
}

private func maximumDifference(_ a: Similarity, _ b: Similarity, over points: [SIMD3<Double>]) -> Double {
    points.map { simd_distance(a.apply($0), b.apply($0)) }.max() ?? 0
}

/// Points spread over a few hundred metres of the anchor frame.
private let samplePoints: [SIMD3<Double>] = [
    SIMD3(0, 0, 0), SIMD3(300, 0, 0), SIMD3(0, 0, -300), SIMD3(-200, 120, 250), SIMD3(50, -40, 10),
]

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

struct LegacySeamTests {
    /// With the streamer anchored at the focus, the tiles root placed through
    /// the georeference is exactly today's placement.
    @Test(arguments: [600.0, 30_000, 200_000, 2_000_000])
    func georeferenceReproducesTodaysPlacement(radius: Double) {
        for presentation in [volume, immersive5] {
            let legacy = state(radius: radius)
            let expected = LegacyMapping.placement(legacy, presentation)
            let placed = LegacyMapping.georeference(legacy, presentation).placement(of: LegacyMapping.anchor(legacy))
            let tolerance = 1e-9 * expected.scale * 1_000
            #expect(maximumDifference(placed, expected, over: samplePoints) < tolerance)
            #expect(abs(placed.scale / expected.scale - 1) < 1e-12)
        }
    }

    @Test func heldPoseComposesAfterThePlacement() {
        let legacy = state(radius: 600)
        let heldPose = Similarity(scale: 1.5, rotation: simd_quatd(angle: 30 * degrees, axis: SIMD3(0, 1, 0)),
                             translation: SIMD3(0.4, 0, -0.3))
        let expected = heldPose.after(LegacyMapping.placement(legacy, immersive5))
        let placed = LegacyMapping.georeference(legacy, immersive5, heldPose: heldPose).placement(of: LegacyMapping.anchor(legacy))
        #expect(maximumDifference(placed, expected, over: samplePoints) < 1e-9)
    }

    /// Tiles placed relative to a different (held) anchor land in the same
    /// place: the root follows whatever anchor the streamer is on.
    @Test func placementFollowsWhicheverAnchorTheStreamerUses() {
        let legacy = state(radius: 600)
        let georeference = LegacyMapping.georeference(legacy, volume)
        let held = StreamingAnchor(coordinate: GeoCoordinate(latitude: 37.80, longitude: -122.40), height: 10)
        let world = Geodesy.ecef(latitude: 37.7962, longitude: -122.3951, height: 25)
        let local = held.ecefFromAnchor.inverse.apply(world)
        #expect(simd_distance(georeference.placement(of: held).apply(local), georeference.map(world)) < 1e-9)
    }
}

struct AdaptiveModelTests {
    /// Up to regional scale the eye-level placement reproduces the original
    /// untilted placement for the camera at the original viewer, to within
    /// the difference between levelling at the focus (the original) and at
    /// the ground beneath the camera (now): under a millimetre at 600 m.
    @Test(arguments: [(600.0, 1e-3), (20_000.0, 2e-2)])
    func matchesTheOriginalPlacementUpClose(radius: Double, tolerance: Double) {
        for presentation in [volume, immersive5] {
            let legacy = state(radius: radius)
            let georeference = LegacyMapping.georeference(legacy, presentation)
            let eye = presentation.viewerPosition
            let centre = LegacyMapping.tiltedGroundPosition(legacy, presentation)
            let camera = CameraPose(position: georeference.ecef(map: eye),
                                    forward: georeference.rotation.inverse.act(simd_normalize(centre - eye)))
            let framing = EyeLevelModel.framing(camera: camera, room: roomGeometry(presentation),
                                                groundHeight: legacy.focusHeight, tiltWeight: 0)
            let anchor = LegacyMapping.anchor(legacy)
            let difference = maximumDifference(framing.georeference.placement(of: anchor),
                                               georeference.placement(of: anchor),
                                               over: samplePoints.map { $0 * radius / 600 })
            #expect(difference < tolerance * presentation.magnification)
        }
    }

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
