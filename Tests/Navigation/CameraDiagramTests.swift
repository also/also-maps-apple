import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

/// The hosts' geometry, as MapPresentation defines it.
private let volume = RoomGeometry(designEye: SIMD3(0, 0.3, 0.85),
                                  placementLevel: SIMD3(0, -0.25, 0),
                                  placementDown: SIMD3(0, 0, 0),
                                  contentHalfWidth: 0.5)
private let immersive = RoomGeometry(designEye: SIMD3(0, 1.6, 0),
                                     placementLevel: SIMD3(0, 0.02, -5.6),
                                     placementDown: SIMD3(0, 1.3, -5.6),
                                     contentHalfWidth: 5)

/// The view state from the descent bug: 927 km up, looking straight down
/// over Ontario, with the envelope following the Earth's curve.
private let bugCamera = CameraPose(latitude: 50.5086, longitude: -88.4861, height: 927_700,
                                   heading: 156.05 * degrees, pitch: -89.994 * degrees)

private func diagram(_ camera: CameraPose, _ presentation: CameraDiagram.Presentation,
                     terrain: Double = 0, ray: Double = 0, envelope: Double = 0) -> CameraDiagram {
    CameraDiagram(CameraDiagram.Inputs(camera: camera, presentation: presentation, terrainHeight: terrain,
                                       rayHeight: ray, envelopeHeight: envelope, containerSize: nil))
}

struct CameraDiagramTests {
    @Test func windowViewerIsTheCamera() {
        let camera = CameraPose(latitude: 37.8, longitude: -122.4, height: 1_200, heading: 0.4, pitch: -0.3)
        let d = diagram(camera, .window(fieldOfView: .pi / 4), terrain: 200)
        #expect(simd_distance(d.viewer.position, d.camera.position) < 1e-3)
        #expect(abs(d.viewerAltitude - 1_000) < 1e-3)
        #expect(d.room == nil)
        #expect(d.georeferencePoint != nil)
        #expect(abs(d.camera.position.x) < 1e-6)
    }

    @Test func volumePutsTheCameraOnTheEyeWhenNothingIsLifted() throws {
        let camera = CameraPose(latitude: 37.8, longitude: -122.4, height: 2_000, heading: 0, pitch: -40 * degrees)
        let d = diagram(camera, .adaptive(volume))
        let room = try #require(d.room)
        #expect(simd_distance(room.camera, room.eye) < 1e-6)
        #expect(abs(d.viewerAltitude - d.cameraAltitude) < 1e-3)
        let placed = try #require(d.placedPoint), g = try #require(d.georeferencePoint)
        #expect(simd_distance(placed, g) < 1e-3)
        #expect(simd_distance(room.placement, CameraDiagram.side(volume.placementLevel)) < 0.3)
    }

    @Test func volumeLiftPutsTheEyeBelowTheCamera() throws {
        let far = diagram(bugCamera, .adaptive(volume), terrain: -50, ray: -49.8, envelope: -20_822)
        #expect(abs(far.lift - 20_772) < 1)
        #expect(abs(far.viewerAltitude - (far.cameraAltitude - far.lift)) < 50)
        #expect(far.viewerAltitude > 0)

        // Descend with the estimates unchanged, as during a gesture: the eye
        // passes through the ground.
        var low = bugCamera
        low.height = 5_000
        let near = diagram(low, .adaptive(volume), terrain: -50, ray: -49.8, envelope: -20_822)
        #expect(near.viewerAltitude < -10_000)
        let room = try #require(near.room)
        #expect(room.camera.y > room.eye.y)
    }

    @Test func immersivePutsTheCameraOnTheEye() throws {
        let camera = CameraPose(latitude: 37.8, longitude: -122.4, height: 800, heading: 1, pitch: -0.2)
        let d = diagram(camera, .eyeLevel(immersive), terrain: 30, ray: 30, envelope: 30)
        let room = try #require(d.room)
        #expect(simd_distance(room.camera, room.eye) < 1e-6)
        #expect(abs(d.viewerAltitude - 770) < 1e-3)
        // Untilted, the terrain under the camera is on the base plane below the eye.
        let terrain = try #require(d.surfaces.first { $0.kind == .terrain })
        let below = try #require(terrain.room.min { abs($0.x - room.eye.x) < abs($1.x - room.eye.x) })
        #expect(abs(below.y - immersive.placementLevel.y) < 0.01)
    }

    @Test func tiltingPastTheHorizonKeepsTheFraming() throws {
        var camera = CameraPose(latitude: 50, longitude: -125, height: 1_500_000, heading: 0.2, pitch: 0)
        func at(_ pitch: Double) -> CameraDiagram {
            camera.pitch = pitch
            return diagram(camera, .window(fieldOfView: .pi / 4))
        }
        // The pitch where the view ray stops meeting the ground.
        var low = -Double.pi / 2, high = 0.0
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if at(mid).georeferencePoint != nil { low = mid } else { high = mid }
        }
        let hitting = at(low), missing = at(high + 1e-9)
        #expect(hitting.georeferencePoint != nil)
        #expect(missing.georeferencePoint == nil)
        #expect(missing.rangeToGeoreference == nil)
        let change = simd_length(missing.worldBounds.size - hitting.worldBounds.size) / simd_length(hitting.worldBounds.size)
        #expect(change < 0.05)
        #expect(abs(try #require(hitting.groundDistanceToGeoreference) - hitting.horizonDistance)
                < 0.05 * hitting.horizonDistance)
    }

    @Test func streamedAreaFollowsEachHostsPolicy() throws {
        let camera = CameraPose(latitude: 37.8, longitude: -122.4, height: 3_000, heading: 0.5, pitch: -40 * degrees)
        let volumeDiagram = diagram(camera, .adaptive(volume))
        #expect(abs(volumeDiagram.streamingRadius - (try #require(volumeDiagram.shownRadius))) < 1e-6)
        var inputs = CameraDiagram.Inputs(camera: camera, presentation: .eyeLevel(immersive), terrainHeight: 0,
                                          rayHeight: 0, envelopeHeight: 0, containerSize: nil)
        inputs.areaPolicy = .horizon(limitPerAltitude: nil)
        let immersiveDiagram = CameraDiagram(inputs)
        #expect(abs(immersiveDiagram.streamingRadius - AOIPolicy.visibleDistance(altitude: 3_000)) < 1)
        #expect(immersiveDiagram.streamedArea.count > 1)
    }

    @Test func pitchAssistLooksStraightDownFarUpAndKeepsG() throws {
        let context = NavigationContext(cameraGround: 0, minimumAltitude: 55, maximumAltitude: 20_000_000)
        var camera = CameraPose(latitude: 37.8, longitude: -122.4, height: 900_000, heading: 0.3,
                                pitch: volume.levelPitch)
        let g = try #require(AdaptiveModel.framing(camera: camera, room: volume, rayHeight: 0, envelopeHeight: 0))
            .georeferencePoint
        for _ in 0..<300 {
            camera = AdaptiveModel.easedPitch(camera, room: volume, rayHeight: 0, envelopeHeight: 0,
                                              context: context, deltaTime: 1.0 / 60)
        }
        #expect(abs(camera.pitch + .pi / 2) < 1e-3)
        let after = try #require(AdaptiveModel.framing(camera: camera, room: volume, rayHeight: 0, envelopeHeight: 0))
        #expect(simd_distance(after.georeferencePoint, g) < 1)
    }

    @Test func settledEnvelopeFollowsTheCurveFarOut() {
        let near = CameraPose(latitude: 37.8, longitude: -122.4, height: 2_000, heading: 0, pitch: -.pi / 2)
        #expect(CameraDiagram.settledEstimates(camera: near, room: volume, terrainHeight: 12) == (12, 12))
        let settled = CameraDiagram.settledEstimates(camera: bugCamera, room: volume, terrainHeight: 0)
        #expect(settled.ray == 0)
        #expect(settled.envelope < -10_000)
    }

    @Test func farOutTheWorldViewGoesRoundTheEarth() {
        let camera = CameraPose(latitude: 0, longitude: 0, height: 20_000_000, heading: 0, pitch: -.pi / 2)
        let d = diagram(camera, .window(fieldOfView: .pi / 4))
        #expect(d.surfaces.allSatisfy { $0.closesWorld })
        #expect(d.worldBounds.size.x > GeoMath.earthRadius)
    }
}
