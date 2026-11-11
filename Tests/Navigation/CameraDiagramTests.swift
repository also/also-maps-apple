import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

/// The hosts' geometry, as MapPresentation defines it.
private let volume: RoomGeometry = {
    let eye = SIMD3<Double>(0, 0.3, 0.85), level = SIMD3<Double>(0, -0.25, 0), down = SIMD3<Double>(0, 0, 0)
    return RoomGeometry(designEye: eye, placementLevel: level, contentHalfWidth: 0.5,
                        fullTilt: RoomGeometry.tiltFacing(down, from: eye))
}()
private let immersive = RoomGeometry(designEye: SIMD3(0, 1.6, 0),
                                     placementLevel: SIMD3(0, 0.02, -5.6),
                                     contentHalfWidth: 5)

private func diagram(_ camera: CameraPose, _ presentation: CameraDiagram.Presentation,
                     terrain: Double = 0, ground: Double = 0, tiltWeight: Double? = nil) -> CameraDiagram {
    var inputs = CameraDiagram.Inputs(camera: camera, presentation: presentation, terrainHeight: terrain,
                                      groundHeight: ground, containerSize: nil)
    inputs.tiltWeight = tiltWeight
    return CameraDiagram(inputs)
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

    @Test(arguments: [volume, immersive])
    func roomHostsPutTheCameraOnTheEyeAndTheGroundOnTheBase(room: RoomGeometry) throws {
        let camera = CameraPose(latitude: 37.8, longitude: -122.4, height: 830, heading: 1, pitch: -0.2)
        let d = diagram(camera, .room(room), terrain: 30, ground: 30)
        let r = try #require(d.room)
        #expect(simd_distance(r.camera, r.eye) < 1e-6)
        #expect(abs(d.viewerAltitude - 800) < 1e-3)
        #expect(d.tiltWeight == 0)
        #expect(r.tilt == 0)
        // Level, the terrain under the camera is on the base plane below the eye.
        let terrain = try #require(d.surfaces.first { $0.kind == .terrain })
        let below = try #require(terrain.room.min { abs($0.x - r.eye.x) < abs($1.x - r.eye.x) })
        #expect(abs(below.y - room.placementLevel.y) < 0.01)
    }

    @Test func tiltFollowsTheCamerasHeight() throws {
        func at(_ height: Double) throws -> (CameraDiagram, CameraDiagram.Room) {
            let camera = CameraPose(latitude: 37.8, longitude: -122.4, height: height, heading: 0.3, pitch: -0.4)
            let d = diagram(camera, .room(volume))
            return (d, try #require(d.room))
        }
        let (low, lowRoom) = try at(20_000)
        #expect(low.tiltWeight == 0)
        #expect(simd_distance(lowRoom.sightLine, simd_normalize(lowRoom.levelPlacement - lowRoom.eye)) < 1e-9)

        let (mid, midRoom) = try at(150_000)
        #expect(mid.tiltWeight > 0 && mid.tiltWeight < 1)
        #expect(abs(midRoom.tilt - mid.tiltWeight * volume.fullTilt) < 1e-9)

        let (high, highRoom) = try at(1_000_000)
        #expect(high.tiltWeight == 1)
        #expect(abs(highRoom.tilt - volume.fullTilt) < 1e-9)
        // The volume's view center is on the line of sight, toward the box's
        // centre at full tilt.
        let toBoxCentre = simd_normalize(CameraDiagram.side(SIMD3(0, 0, 0) - volume.designEye))
        #expect(simd_distance(highRoom.sightLine, toBoxCentre) < 1e-9)
        let toPlacement = simd_normalize(highRoom.placement - highRoom.eye)
        #expect(simd_distance(highRoom.sightLine, toPlacement) < 1e-3)
    }

    @Test func aGivenTiltWeightOverridesTheAssist() throws {
        let camera = CameraPose(latitude: 37.8, longitude: -122.4, height: 1_000_000, heading: 0, pitch: 0)
        let d = diagram(camera, .room(immersive), tiltWeight: 0)
        #expect(d.tiltWeight == 0)
        #expect(try #require(d.room).tilt == 0)
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
        let volumeDiagram = diagram(camera, .room(volume))
        #expect(abs(volumeDiagram.streamingRadius - (try #require(volumeDiagram.shownRadius))) < 1e-6)
        var inputs = CameraDiagram.Inputs(camera: camera, presentation: .room(immersive), terrainHeight: 0,
                                          groundHeight: 0, containerSize: nil)
        inputs.areaPolicy = .horizon(limitPerAltitude: nil)
        let immersiveDiagram = CameraDiagram(inputs)
        #expect(abs(immersiveDiagram.streamingRadius - AOIPolicy.visibleDistance(altitude: 3_000)) < 1)
        #expect(immersiveDiagram.streamedArea.count > 1)
    }

    @Test func farOutTheWorldViewGoesRoundTheEarth() {
        let camera = CameraPose(latitude: 0, longitude: 0, height: 20_000_000, heading: 0, pitch: -.pi / 2)
        let d = diagram(camera, .window(fieldOfView: .pi / 4))
        #expect(d.surfaces.allSatisfy { $0.closesWorld })
        #expect(d.worldBounds.size.x > GeoMath.earthRadius)
    }
}
