import Foundation
import simd

/// The world in miniature: a tabletop copy of the world around the eye,
/// shown in the volume while the immersive space is open. It's a separate
/// view of the same camera, at a much smaller, fixed scale, with its own
/// tiles. Navigation never reads it; going somewhere by pointing at it is a
/// camera operation like any other (`jump`, `slid`).
///
/// The table frame is the volume's scene space: metres, y up, −z away from
/// someone standing in front of the volume, its origin the volume's centre.
struct MiniatureLayout: Equatable {
    /// Which way the table is turned.
    enum Orientation: String, Codable, CaseIterable {
        /// The camera's heading points away from the viewer (into the
        /// volume), so what's ahead of you in the immersive map is ahead on
        /// the table too. The table turns as you turn.
        case headingUp
        /// North points into the volume; your marker turns instead.
        case northUp
    }

    /// World metres from the table's centre to its edge.
    var halfWidth = 5_000.0 {
        didSet { halfWidth = Self.clampedHalfWidth(halfWidth) }
    }
    var orientation = Orientation.headingUp
    /// Where the ground beneath the eye goes, table frame. A little above
    /// the volume's floor (−0.3 m), so terrain somewhat lower than the
    /// ground there still shows rather than falling out of the volume.
    var tableGround = SIMD3<Double>(0, -0.2, 0)
    /// Half-width of the table, metres: the volume's half-width, which
    /// clips whatever reaches past it.
    var tableHalfWidth = 0.5
    /// Highest a marker is drawn, table frame: just under the volume's top
    /// (0.3 m). Above it the eye is drawn here, on a post from the ground.
    var ceiling = 0.27

    /// From a couple of kilometres across to tens of kilometres.
    static let halfWidthRange = 1_000.0...30_000.0
    /// The streamed square reaches this much past the table's edge, so tiles
    /// coming onto the table as you fly are already there.
    static let streamingMargin = 1.25

    static func clampedHalfWidth(_ value: Double) -> Double {
        guard value.isFinite else { return halfWidthRange.lowerBound }
        return min(max(value, halfWidthRange.lowerBound), halfWidthRange.upperBound)
    }

    /// Table metres per world metre.
    var scale: Double { tableHalfWidth / halfWidth }

    /// The heading that points into the volume, radians clockwise from north.
    func tableHeading(cameraHeading: Double) -> Double {
        orientation == .northUp ? 0 : cameraHeading
    }

    /// ECEF → table frame for a table centred on `centre`, with the ground
    /// there (`groundHeight`, metres above the ellipsoid) on `tableGround`,
    /// level, turned for `cameraHeading`.
    func georeference(centre: GeoCoordinate, groundHeight: Double, cameraHeading: Double) -> Georeference {
        let heading = tableHeading(cameraHeading: cameraHeading)
        let frame = Geodesy.enu(latitude: centre.latitude, longitude: centre.longitude)
        let forward = frame.north * cos(heading) + frame.east * sin(heading)
        let right = frame.east * cos(heading) - frame.north * sin(heading)
        // Rows: where right, up and back (+z) come from.
        let rotation = simd_quatd(simd_double3x3(rows: [right, frame.up, -forward]))
        let ground = Geodesy.ecef(centre, height: groundHeight)
        return Georeference(scale: scale, rotation: rotation,
                            translation: tableGround - scale * rotation.act(ground))
    }

    /// The point on the globe under a table point (any height on the table
    /// gives the same answer near the centre; far out, the point is read
    /// along the table's vertical, which is within a fraction of a percent).
    func coordinate(atTable point: SIMD3<Double>, georeference: Georeference) -> GeoCoordinate {
        var level = point
        level.y = tableGround.y
        return Geodesy.geodetic(georeference.ecef(map: level)).coordinate
    }

    /// Whether a table point is on the table, not past its edge.
    func isOnTable(_ point: SIMD3<Double>) -> Bool {
        abs(point.x - tableGround.x) <= tableHalfWidth && abs(point.z - tableGround.z) <= tableHalfWidth
    }

    // MARK: Markers

    /// Where you are on the table.
    struct Marker: Equatable {
        /// The eye, table frame; at most `ceiling` high.
        var eye: SIMD3<Double>
        /// The ground beneath it.
        var nadir: SIMD3<Double>
        /// The eye is higher than the table can show, so it's drawn at the
        /// ceiling.
        var isClamped: Bool
        /// Unit, horizontal: the camera's heading (which way you move).
        var heading: SIMD3<Double>
    }

    func marker(camera: CameraPose, groundHeight: Double, georeference: Georeference) -> Marker {
        var eye = georeference.map(camera.position)
        let nadir = georeference.map(Geodesy.ecef(camera.coordinate, height: groundHeight))
        let isClamped = eye.y > ceiling
        if isClamped { eye.y = ceiling }
        let frame = Geodesy.enu(latitude: camera.latitude, longitude: camera.longitude)
        let forward = frame.north * cos(camera.heading) + frame.east * sin(camera.heading)
        var heading = georeference.rotation.act(forward)
        heading.y = 0
        let length = simd_length(heading)
        return Marker(eye: eye, nadir: nadir, isClamped: isClamped,
                      heading: length > 1e-9 ? heading / length : SIMD3(0, 0, -1))
    }

    /// A direction in the world (ECEF) on the table: unit, or nil if it's
    /// degenerate.
    func tableDirection(_ ecef: SIMD3<Double>, georeference: Georeference) -> SIMD3<Double>? {
        let direction = georeference.rotation.act(ecef)
        let length = simd_length(direction)
        return length > 1e-9 && length.isFinite ? direction / length : nil
    }

    /// The square the main map's streamer is limited to (the bridge's
    /// excluder: axis-aligned in east and north at its anchor, grown to
    /// enclose the turned region), as four table points on the table's
    /// ground. Usually far bigger than the table when streaming reaches the
    /// horizon; the volume clips it.
    func streamedOutline(_ inputs: StreamingInputs, georeference: Georeference) -> [SIMD3<Double>] {
        let r = inputs.streamingRadius * (abs(sin(inputs.regionHeading)) + abs(cos(inputs.regionHeading)))
        let ecefFromAnchor = inputs.anchor.ecefFromAnchor
        // Anchor frame: x east, z south.
        let corners: [SIMD3<Double>] = [[-r, 0, -r], [r, 0, -r], [r, 0, r], [-r, 0, r]]
        return corners.map { corner in
            var point = georeference.map(ecefFromAnchor.apply(corner))
            point.y = tableGround.y
            return point
        }
    }

    // MARK: Streaming

    /// What the miniature's own streamer is told: anchored on the ground
    /// beneath the eye, a square a little bigger than the table turned with
    /// it, and detail chosen for a camera straight above that sees all of it.
    func streamingInputs(centre: GeoCoordinate, groundHeight: Double, cameraHeading: Double) -> StreamingInputs {
        let heading = tableHeading(cameraHeading: cameraHeading)
        let radius = halfWidth * Self.streamingMargin
        let fieldOfView = Double.pi / 3
        // Far enough above that the square's corners are inside the view, so
        // the whole table is selected at the inside detail. On the bridge's
        // 2048-pixel view this puts the table about as many pixels across as
        // the real one (1 m, seen from about a metre) covers on the display.
        let distance = radius * 2.squareRoot() / tan(fieldOfView / 2)
        var lod = LODCamera.orbit(heading: heading, elevation: .pi / 2, distance: distance)
        lod.fieldOfView = fieldOfView
        return StreamingInputs(anchor: StreamingAnchor(coordinate: centre, height: groundHeight),
                               lod: lod, regionHeading: heading, streamingRadius: radius)
    }

    // MARK: Navigation

    /// Travels straight to `target` along the globe with
    /// NavigationOperations.move: height above the ellipsoid stays, and both
    /// headings are carried along the great circle, as flying there would.
    /// The caller keeps height above the ground by moving the camera with
    /// the ground once it's known there, and starts a new track segment.
    static func jump(_ state: NavigationState, to target: GeoCoordinate) -> NavigationState {
        let start = state.camera.coordinate
        let distance = GeoMath.distance(from: start, to: target)
        guard distance > 1e-6, distance.isFinite else { return state }
        let relative = GeoMath.bearing(from: start, to: target) - state.movementHeading
        return NavigationOperations.move(state, forward: distance * cos(relative),
                                         right: distance * sin(relative))
    }

    /// The camera after dragging the table from `from` to `to` (table
    /// points), starting from `start`, the state when the drag began. The
    /// world grabbed stays under the hand, as when dragging the main map:
    /// since the table follows you, you travel the other way, by the drag
    /// divided by the scale.
    func slid(_ start: NavigationState, from: SIMD3<Double>, to: SIMD3<Double>) -> NavigationState {
        let drag = to - from
        let heading = tableHeading(cameraHeading: start.camera.heading)
        // Table x is right of the table heading, −z ahead of it. The camera
        // moves opposite to the hand.
        let ahead = drag.z / scale, right = -drag.x / scale
        let distance = (ahead * ahead + right * right).squareRoot()
        guard distance > 1e-9, distance.isFinite else { return start }
        let relative = heading + atan2(right, ahead) - start.movementHeading
        return NavigationOperations.move(start, forward: distance * cos(relative),
                                         right: distance * sin(relative))
    }
}
