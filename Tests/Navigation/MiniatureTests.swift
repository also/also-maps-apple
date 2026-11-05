import Foundation
import simd
import Testing

private let degrees = Double.pi / 180
private let ronda = GeoCoordinate(latitude: 36.7377, longitude: -5.1728)

private func camera(heading: Double = 40 * degrees, height: Double = 1_200) -> CameraPose {
    CameraPose(latitude: ronda.latitude, longitude: ronda.longitude, height: height,
               heading: heading, pitch: -0.3)
}

struct MiniatureLayoutTests {
    @Test(arguments: [MiniatureLayout.Orientation.headingUp, .northUp])
    func groundBeneathTheEyeIsOnTheTableLevel(orientation: MiniatureLayout.Orientation) {
        var layout = MiniatureLayout()
        layout.orientation = orientation
        let c = camera()
        let g = layout.georeference(centre: c.coordinate, groundHeight: 600, cameraHeading: c.heading)
        #expect(simd_distance(g.map(Geodesy.ecef(ronda, height: 600)), layout.tableGround) < 1e-6)
        let up = Geodesy.enu(latitude: ronda.latitude, longitude: ronda.longitude).up
        #expect(simd_distance(g.rotation.act(up), SIMD3(0, 1, 0)) < 1e-9)
        #expect(abs(g.scale - 0.5 / 5_000) < 1e-12)
    }

    @Test func headingUpPointsTheHeadingIntoTheVolume() {
        let layout = MiniatureLayout()
        let c = camera(heading: 130 * degrees)
        let g = layout.georeference(centre: c.coordinate, groundHeight: 600, cameraHeading: c.heading)
        let marker = layout.marker(camera: c, groundHeight: 600, georeference: g)
        #expect(simd_distance(marker.heading, SIMD3(0, 0, -1)) < 1e-9)
    }

    @Test func northUpPointsNorthIntoTheVolume() {
        var layout = MiniatureLayout()
        layout.orientation = .northUp
        let c = camera(heading: 90 * degrees)
        let g = layout.georeference(centre: c.coordinate, groundHeight: 600, cameraHeading: c.heading)
        let north = Geodesy.enu(latitude: ronda.latitude, longitude: ronda.longitude).north
        #expect(simd_distance(g.rotation.act(north), SIMD3(0, 0, -1)) < 1e-9)
        // Facing east, the marker points right.
        let marker = layout.marker(camera: c, groundHeight: 600, georeference: g)
        #expect(simd_distance(marker.heading, SIMD3(1, 0, 0)) < 1e-9)
    }

    @Test func eyeIsAboveTheGroundAtScaleAndClampedAtTheCeiling() {
        let layout = MiniatureLayout()
        let low = camera(height: 1_100)
        let g = layout.georeference(centre: low.coordinate, groundHeight: 600, cameraHeading: low.heading)
        let marker = layout.marker(camera: low, groundHeight: 600, georeference: g)
        #expect(!marker.isClamped)
        #expect(abs(marker.eye.y - (layout.tableGround.y + 500 * layout.scale)) < 1e-6)
        #expect(simd_distance(marker.nadir, layout.tableGround) < 1e-6)

        let high = camera(height: 20_000)
        let clamped = layout.marker(camera: high, groundHeight: 600, georeference: g)
        #expect(clamped.isClamped)
        #expect(clamped.eye.y == layout.ceiling)
    }

    @Test(arguments: [MiniatureLayout.Orientation.headingUp, .northUp])
    func tablePointsRoundTripToTheGlobe(orientation: MiniatureLayout.Orientation) {
        var layout = MiniatureLayout()
        layout.orientation = orientation
        layout.halfWidth = 20_000
        let c = camera()
        let g = layout.georeference(centre: c.coordinate, groundHeight: 600, cameraHeading: c.heading)
        let target = GeoMath.offset(ronda, east: 7_000, north: -12_000)
        let onTable = g.map(Geodesy.ecef(target, height: 600))
        let back = layout.coordinate(atTable: onTable, georeference: g)
        #expect(GeoMath.distance(from: back, to: target) < 30)
        #expect(layout.isOnTable(onTable))
    }

    @Test func halfWidthIsClamped() {
        var layout = MiniatureLayout()
        layout.halfWidth = 10
        #expect(layout.halfWidth == MiniatureLayout.halfWidthRange.lowerBound)
        layout.halfWidth = 1e9
        #expect(layout.halfWidth == MiniatureLayout.halfWidthRange.upperBound)
        layout.halfWidth = .nan
        #expect(layout.halfWidth == MiniatureLayout.halfWidthRange.lowerBound)
    }

    @Test func streamingCoversTheTableFromStraightAbove() {
        let layout = MiniatureLayout()
        let c = camera(heading: 70 * degrees)
        let inputs = layout.streamingInputs(centre: c.coordinate, groundHeight: 600, cameraHeading: c.heading)
        #expect(inputs.anchor.coordinate == c.coordinate)
        #expect(inputs.anchor.height == 600)
        #expect(inputs.streamingRadius > layout.halfWidth)
        #expect(abs(inputs.regionHeading - c.heading) < 1e-12)
        // Straight down, perpendicular unit vectors, with the corners inside.
        #expect(simd_distance(inputs.lod.direction, SIMD3(0, -1, 0)) < 1e-9)
        #expect(abs(simd_dot(inputs.lod.direction, inputs.lod.up)) < 1e-9)
        #expect(abs(simd_length(inputs.lod.up) - 1) < 1e-9)
        let corner = inputs.streamingRadius * 2.squareRoot()
        #expect(atan(corner / inputs.lod.position.y) <= inputs.lod.fieldOfView / 2 + 1e-9)
    }

    @Test func streamedOutlineIsTheExcludersSquare() {
        let layout = MiniatureLayout()
        let c = camera(heading: 0)
        let g = layout.georeference(centre: c.coordinate, groundHeight: 600, cameraHeading: 0)
        var main = StreamingInputs(anchor: StreamingAnchor(coordinate: ronda, height: 600))
        main.streamingRadius = 2_000
        main.regionHeading = 0
        let corners = layout.streamedOutline(main, georeference: g)
        #expect(corners.count == 4)
        for corner in corners {
            #expect(abs(abs(corner.x) - 2_000 * layout.scale) < 1e-3)
            #expect(abs(abs(corner.z) - 2_000 * layout.scale) < 1e-3)
            #expect(corner.y == layout.tableGround.y)
        }
    }
}

struct MiniatureNavigationTests {
    @Test(arguments: [(3_000.0, 1_000.0), (-12_000, 4_000), (0, -25_000)])
    func jumpLandsOnTheTargetKeepingHeightAndHeading(east: Double, north: Double) {
        let state = NavigationState(camera: camera(heading: 40 * degrees, height: 1_200))
        let target = GeoMath.offset(ronda, east: east, north: north)
        let jumped = MiniatureLayout.jump(state, to: target)
        #expect(GeoMath.distance(from: jumped.camera.coordinate, to: target) < 0.01)
        #expect(jumped.camera.height == state.camera.height)
        #expect(jumped.camera.pitch == state.camera.pitch)
        // Carried along the great circle: over tens of kilometres at this
        // latitude, the heading changes by a fraction of a degree.
        #expect(abs(jumped.camera.heading - state.camera.heading) < 0.5 * degrees)
        #expect(jumped.movementHeading == jumped.camera.heading)
    }

    @Test func jumpToWhereYouAreChangesNothing() {
        let state = NavigationState(camera: camera())
        #expect(MiniatureLayout.jump(state, to: ronda) == state)
    }

    @Test(arguments: [MiniatureLayout.Orientation.headingUp, .northUp])
    func dragKeepsTheGrabbedWorldUnderTheHand(orientation: MiniatureLayout.Orientation) {
        var layout = MiniatureLayout()
        layout.orientation = orientation
        let start = NavigationState(camera: camera(heading: 60 * degrees))
        let before = layout.georeference(centre: start.camera.coordinate, groundHeight: 600,
                                         cameraHeading: start.camera.heading)
        let from = SIMD3(0.1, layout.tableGround.y, -0.05)
        let to = SIMD3(-0.15, layout.tableGround.y, 0.2)
        let grab = before.ecef(map: from)

        let slid = layout.slid(start, from: from, to: to)
        let after = layout.georeference(centre: slid.camera.coordinate, groundHeight: 600,
                                        cameraHeading: slid.camera.heading)
        var shown = after.map(grab)
        shown.y = to.y
        // A millimetre on the table is 10 m of world at this scale. Moves are
        // steered on a sphere (GeoMath), a fraction of a percent off the
        // ellipsoid the table is drawn on, and the heading carried along the
        // move turns a heading-up table slightly.
        #expect(simd_distance(shown, to) < 2e-3)
        #expect(slid.camera.height == start.camera.height)
    }

    @Test func noDragNoMove() {
        let layout = MiniatureLayout()
        let start = NavigationState(camera: camera())
        let p = SIMD3(0.1, -0.2, 0.1)
        #expect(layout.slid(start, from: p, to: p) == start)
    }
}
