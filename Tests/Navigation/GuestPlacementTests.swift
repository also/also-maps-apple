import Foundation
import simd
import Testing

private let boston = GeoCoordinate(latitude: 42.3555, longitude: -71.0605)
private let grandCanyon = GeoCoordinate(latitude: 36.0995, longitude: -112.1130)

private func placement(_ mode: GuestMode, heading: Double = 0) -> GuestPlacement {
    GuestPlacement(mode: mode, hostCentre: boston, hostRadius: 900,
                   guestCentre: grandCanyon, guestRadius: 8_000, heading: heading)
}

/// Local east, north and up metres of `point` from `origin` (both ECEF),
/// in the level frame at `origin`.
private func local(_ point: SIMD3<Double>, from origin: SIMD3<Double>) -> SIMD3<Double> {
    let (coordinate, _) = Geodesy.geodetic(origin)
    let frame = Geodesy.enu(latitude: coordinate.latitude, longitude: coordinate.longitude)
    let d = point - origin
    return SIMD3(simd_dot(d, frame.east), simd_dot(d, frame.north), simd_dot(d, frame.up))
}

struct GuestModeTests {
    @Test func parsesTheEnvironmentValues() {
        #expect(GuestMode(environmentValue: "side") == .sideBySide)
        #expect(GuestMode(environmentValue: "Side-By-Side") == .sideBySide)
        #expect(GuestMode(environmentValue: "overlay") == .overlay)
        #expect(GuestMode(environmentValue: "beside") == nil)
    }
}

struct SideBySideTests {
    @Test func guestCentreSitsEastByBothRadiiAndTheGap() {
        let p = placement(.sideBySide)
        #expect(p.separation == 900 + 8_000 + 890)
        let shown = p.shownCentre
        #expect(abs(GeoMath.distance(from: boston, to: shown) - p.separation) < 1)
        #expect(abs(GeoMath.bearing(from: boston, to: shown) - .pi / 2) < 1e-3)
    }

    @Test func keepsTheGuestsOwnHeights() {
        let p = placement(.sideBySide)
        // The canyon's rim, about 2,100 m up, stays 2,100 m up beside Boston.
        let rim = p.shownFromReal.apply(Geodesy.ecef(grandCanyon, height: 2_100))
        let (coordinate, height) = Geodesy.geodetic(rim)
        #expect(abs(height - 2_100) < 1e-3)
        #expect(GeoMath.distance(from: coordinate, to: p.shownCentre) < 1e-3)
    }

    @Test func northStaysNorthUnturned() {
        let p = placement(.sideBySide)
        let north = GeoMath.offset(grandCanyon, east: 0, north: 100)
        let shownOrigin = p.shownFromReal.apply(Geodesy.ecef(grandCanyon, height: 0))
        let offset = local(p.shownFromReal.apply(Geodesy.ecef(north, height: 0)), from: shownOrigin)
        #expect(abs(offset.x) < 0.01)
        #expect(abs(offset.y - 100) < 0.5)
    }

    @Test func isPlacedWithoutGroundSamples() {
        #expect(placement(.sideBySide).isPlaced)
    }
}

struct OverlayTests {
    @Test func waitsForBothGroundSamples() {
        var p = placement(.overlay)
        #expect(!p.isPlaced)
        p.hostGround = 10
        #expect(!p.isPlaced)
        p.guestGround = 2_100
        #expect(p.isPlaced)
    }

    @Test func putsTheGuestsGroundOnTheHosts() {
        var p = placement(.overlay)
        p.hostGround = 10
        p.guestGround = 2_100
        let ground = p.shownFromReal.apply(Geodesy.ecef(grandCanyon, height: 2_100))
        let (coordinate, height) = Geodesy.geodetic(ground)
        #expect(abs(height - 10) < 1e-3)
        #expect(GeoMath.distance(from: coordinate, to: boston) < 1e-3)
    }

    @Test(arguments: [0.0, 0.5, Double.pi / 2, 3.0])
    func turnsTheGuestsNorthToTheHeading(heading: Double) {
        var p = placement(.overlay, heading: heading)
        p.hostGround = 0
        p.guestGround = 0
        let north = GeoMath.offset(grandCanyon, east: 0, north: 100)
        let offset = local(p.shownFromReal.apply(Geodesy.ecef(north, height: 0)),
                           from: Geodesy.ecef(boston, height: 0))
        // Clockwise from north: east is sin, north is cos.
        #expect(abs(offset.x - 100 * sin(heading)) < 0.5)
        #expect(abs(offset.y - 100 * cos(heading)) < 0.5)
    }
}

struct DisplacedStreamTests {
    @Test(arguments: [GuestMode.sideBySide, .overlay])
    func guestPlacementIsRigid(mode: GuestMode) {
        var p = placement(mode, heading: 0.7)
        p.hostGround = 5
        p.guestGround = 1_800
        let transform = p.shownFromReal
        #expect(abs(transform.scale - 1) < 1e-12)
        let a = Geodesy.ecef(grandCanyon, height: 1_800)
        let b = Geodesy.ecef(GeoMath.offset(grandCanyon, east: 3_000, north: -1_200), height: 900)
        #expect(abs(simd_distance(transform.apply(a), transform.apply(b)) - simd_distance(a, b)) < 1e-5)
    }

    @Test func lodCameraIsTheHostsCarriedBack() {
        var p = placement(.overlay, heading: 1.1)
        p.hostGround = 5
        p.guestGround = 1_800
        let stream = p.stream
        let hostAnchor = StreamingAnchor(coordinate: GeoMath.offset(boston, east: 200, north: -50), height: 5)
        let hostLOD = LODCamera.orbit(heading: 0.4, elevation: 0.6, distance: 1_500)
        let guestLOD = stream.lodCamera(carrying: hostLOD, from: hostAnchor)

        // The guest's LOD camera, shown where the guest is shown, is the host's.
        let guestToHostWorld = stream.shownFromReal.after(stream.anchor.ecefFromAnchor)
        let hostWorld = hostAnchor.ecefFromAnchor
        #expect(simd_distance(guestToHostWorld.apply(guestLOD.position), hostWorld.apply(hostLOD.position)) < 1e-4)
        let direction = guestToHostWorld.rotation.act(guestLOD.direction)
        #expect(simd_distance(direction, hostWorld.rotation.act(hostLOD.direction)) < 1e-9)
        let up = guestToHostWorld.rotation.act(guestLOD.up)
        #expect(simd_distance(up, hostWorld.rotation.act(hostLOD.up)) < 1e-9)
        #expect(guestLOD.fieldOfView == hostLOD.fieldOfView)
        #expect(guestLOD.aspect == hostLOD.aspect)
    }

    @Test func lodCameraOverTheShownCentreIsOverTheGuestsCentre() {
        let p = placement(.sideBySide)
        // A host camera straight above where the guest is shown...
        let hostAnchor = StreamingAnchor(coordinate: p.shownCentre)
        let above = LODCamera(position: SIMD3(0, 3_000, 0), direction: SIMD3(0, -1, 0), up: SIMD3(0, 0, -1))
        let lod = p.stream.lodCamera(carrying: above, from: hostAnchor)
        // ...is straight above the guest's own centre, as high.
        #expect(simd_length(SIMD2(lod.position.x, lod.position.z)) < 1e-3)
        #expect(abs(lod.position.y - 3_000) < 1e-3)
        #expect(simd_distance(lod.direction, SIMD3(0, -1, 0)) < 1e-9)
    }

    @Test func aScaledPlacementMovesTheLODCameraAway() {
        // A miniature: the guest's world at a tenth of its size, centred on
        // its own centre. The same host camera is ten times as far from it.
        let centre = Geodesy.ecef(grandCanyon, height: 0)
        let shrink = Similarity(scale: 0.1, translation: centre - 0.1 * centre)
        let stream = DisplacedStream(anchor: StreamingAnchor(coordinate: grandCanyon), streamingRadius: 500,
                                     shownFromReal: shrink)
        let hostLOD = LODCamera.orbit(heading: 0, elevation: .pi / 2, distance: 200)
        let lod = stream.lodCamera(carrying: hostLOD, from: StreamingAnchor(coordinate: grandCanyon))
        #expect(abs(simd_length(lod.position) - 2_000) < 1e-3)
    }

    @Test func tilesAtTheGuestAnchorLandWhereTheGuestIsShown() {
        let p = placement(.sideBySide, heading: 0.3)
        let stream = p.stream
        // Any georeference: here the host's anchor frame at Boston.
        let georeference = Georeference(StreamingAnchor(coordinate: boston).ecefFromAnchor.inverse)
        let placed = stream.placement(in: georeference).apply(.zero)
        let expected = georeference.map(p.shownFromReal.apply(Geodesy.ecef(grandCanyon, height: 0)))
        #expect(simd_distance(placed, expected) < 1e-4)
        // East of Boston by the separation, near the level plane there.
        #expect(abs(placed.x - p.separation) < 0.01 * p.separation)
        #expect(abs(placed.z) < 0.01 * p.separation)
    }

    @Test func inputsStreamAroundTheGuestsOwnCentre() {
        let p = placement(.sideBySide)
        let inputs = p.stream.inputs(hostLOD: LODCamera(), hostAnchor: StreamingAnchor(coordinate: boston))
        #expect(inputs.anchor.coordinate == grandCanyon)
        #expect(inputs.streamingRadius == 8_000)
    }
}
