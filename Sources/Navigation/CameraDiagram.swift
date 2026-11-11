import Foundation
import simd

/// A side view of how a camera is shown, for explaining and debugging
/// navigation: the world in the camera's vertical plane, and the room as a
/// host lays it out. It's computed with the renderer's own functions (the
/// framing models, the LOD camera, geodesy), so it shows what the app does,
/// not a drawing of it.
///
/// Side views are 2D, in metres: the world's x runs along the camera's
/// heading and y up from the ellipsoid beneath it; the room's x runs away
/// from the viewer (map frame −z) and y up.
struct CameraDiagram {
    enum Presentation: Equatable {
        /// A flat screen: the render camera is the camera.
        case window(fieldOfView: Double)
        /// A room host (the volume or the immersive space), placed by the
        /// eye-level model.
        case room(RoomGeometry)

        var room: RoomGeometry? {
            switch self {
            case .window: nil
            case let .room(room): room
            }
        }
    }

    struct Inputs: Equatable {
        var camera: CameraPose
        var presentation: Presentation
        /// Metres above the ellipsoid. The terrain stands in for the
        /// rendered ground near the camera (the camera ground); the placement
        /// ground is the estimate a room host puts on its base plane.
        var terrainHeight: Double
        var groundHeight: Double
        /// A room host's tilt weight (0...1), or nil for the tilt assist's,
        /// from the camera's height (MapModel's default).
        var tiltWeight: Double?
        /// A room host's fixed scale (1 is human scale), or nil to put the
        /// placement ground on the base plane.
        var fixedScale: Double?
        /// The container's size, centred on the reference space's origin
        /// (the volume), if it has one.
        var containerSize: SIMD3<Double>?
        /// A room host's area of interest policy (MapModel's per host). The
        /// window always streams to the horizon.
        var areaPolicy: AOIPolicy = .georeference(regionMultiplier: 1)
    }

    /// The camera's vertical plane: x along its heading, y up, from the
    /// ellipsoid beneath it.
    struct SidePlane {
        var origin: SIMD3<Double>
        var along: SIMD3<Double>
        var up: SIMD3<Double>

        init(camera: CameraPose) {
            let frame = Geodesy.enu(latitude: camera.latitude, longitude: camera.longitude)
            origin = Geodesy.ecef(camera.coordinate, height: 0)
            along = frame.north * cos(camera.heading) + frame.east * sin(camera.heading)
            up = frame.up
        }

        func point(_ ecef: SIMD3<Double>) -> SIMD2<Double> {
            let d = ecef - origin
            return SIMD2(simd_dot(d, along), simd_dot(d, up))
        }

        /// A unit direction in the plane; straight down if `v` is across it.
        func direction(_ v: SIMD3<Double>) -> SIMD2<Double> {
            let d = SIMD2(simd_dot(v, along), simd_dot(v, up))
            let length = simd_length(d)
            return length > 1e-12 ? d / length : SIMD2(0, -1)
        }
    }

    struct Bounds: Equatable {
        var min: SIMD2<Double>
        var max: SIMD2<Double>

        init(_ points: [SIMD2<Double>]) {
            min = points.dropFirst().reduce(points[0], simd_min)
            max = points.dropFirst().reduce(points[0], simd_max)
        }

        var size: SIMD2<Double> { max - min }
        var centre: SIMD2<Double> { (min + max) / 2 }

        /// Grown by `fraction` of its size on every side, then to a square
        /// at least `minimumSize` across, so views of any shape fit it the
        /// same way.
        func padded(_ fraction: Double, minimumSize: Double) -> Bounds {
            let grown = size * (0.5 + fraction)
            let half = SIMD2(repeating: Swift.max(grown.x, grown.y, minimumSize / 2))
            return Bounds([centre - half, centre + half])
        }
    }

    /// A point of view: where it is, where it looks, and its vertical field
    /// of view if it has a frustum.
    struct Viewpoint {
        var position: SIMD2<Double>
        var direction: SIMD2<Double>
        var fieldOfView: Double?
    }

    struct Surface {
        enum Kind: String, CaseIterable {
            case ellipsoid, terrain, placementGround
        }

        var kind: Kind
        /// Metres above the ellipsoid.
        var height: Double
        var world: [SIMD2<Double>]
        /// As placed in the room; empty for the window.
        var room: [SIMD2<Double>]
        /// The world samples go all the way round the Earth.
        var closesWorld: Bool
    }

    struct Room {
        /// E, the design eye point.
        var eye: SIMD2<Double>
        /// C₀ and C₁: where the georeference point goes level and looking down.
        var levelPlacement: SIMD2<Double>
        var downPlacement: SIMD2<Double>
        /// C(w): the content centre at the current tilt weight.
        var contentCentre: SIMD2<Double>
        /// Where the view centre is placed now.
        var placement: SIMD2<Double>
        /// Where the camera itself lands: on the eye.
        var camera: SIMD2<Double>
        /// The tilt: the world turned about the eye, radians.
        var tilt: Double
        var basePlaneHeight: Double
        var contentHalfWidth: Double
        var container: Bounds?
        /// The LOD camera: from the eye, toward C.
        var lod: Viewpoint
        /// The Earth's centre as placed, for filling the ground's far side.
        var earthCentre: SIMD2<Double>
        /// The streamed area as placed, on the terrain.
        var streamedArea: [SIMD2<Double>]
        var bounds: Bounds
    }

    let inputs: Inputs
    let plane: SidePlane
    let camera: Viewpoint
    /// Where the eye is in the world, and the LOD camera from there. The
    /// window's is the camera; a room host's is the design eye point
    /// through the georeference.
    let viewer: Viewpoint
    /// G: a room host's view centre, on the placement ground; the window's
    /// view ray's hit on the terrain. Nil if the ray misses.
    let georeferencePoint: SIMD2<Double>?
    /// The world point the framing places, back in the world: G itself.
    let placedPoint: SIMD2<Double>?
    /// ±ρ around G along the plane, on the placement ground, sampled along it.
    let shownRegion: [SIMD2<Double>]
    /// The Earth's centre, for filling the ground's far side.
    let earthCentre: SIMD2<Double>
    /// The area of interest streaming is given, across its centre along the
    /// plane, on the terrain. The window's and the immersive space's reach
    /// to the horizon; the volume's is the shown region.
    let streamedArea: [SIMD2<Double>]
    /// Its half-width, metres.
    let streamingRadius: Double
    let surfaces: [Surface]
    let room: Room?
    /// Room metres per world metre.
    let scale: Double?
    /// ρ: half-width of the shown region, world metres.
    let shownRadius: Double?
    /// A room host's tilt weight (0...1); 0 for the window.
    let tiltWeight: Double
    let worldBounds: Bounds
    /// The camera's and the viewer's heights above the terrain, metres.
    /// A negative viewer altitude is underground.
    let cameraAltitude: Double
    let viewerAltitude: Double
    /// From the camera to G, and along the ground from beneath the camera
    /// to G (negative behind), metres. Nil if the view ray misses.
    let rangeToGeoreference: Double?
    let groundDistanceToGeoreference: Double?
    /// Where the terrain's horizon is seen ahead, and how far along the
    /// ground it is from beneath the camera (a sphere's, near enough).
    let horizonPoint: SIMD2<Double>
    let horizonDistance: Double

    init(_ inputs: Inputs) {
        self.inputs = inputs
        let camera = inputs.camera
        let plane = SidePlane(camera: camera)
        self.plane = plane
        let ground = inputs.groundHeight

        var framing: AdaptiveModel.Framing?
        var cameraFieldOfView: Double?
        var weight = 0.0
        switch inputs.presentation {
        case let .window(fieldOfView):
            cameraFieldOfView = fieldOfView
        case let .room(room):
            weight = inputs.tiltWeight ?? EyeLevelModel.tiltWeight(for: camera)
            framing = EyeLevelModel.framing(camera: camera, room: room, groundHeight: ground,
                                            tiltWeight: weight, fixedScale: inputs.fixedScale)
        }
        tiltWeight = weight
        self.camera = Viewpoint(position: plane.point(camera.position),
                                direction: plane.direction(camera.basis.forward),
                                fieldOfView: cameraFieldOfView)

        // What streaming is given: the area of interest and the LOD camera,
        // back in the world.
        let streaming: StreamingInputs
        if let framing, let room = inputs.presentation.room {
            streaming = .room(framing: framing, room: room, camera: camera, policy: inputs.areaPolicy,
                              groundHeight: ground)
        } else {
            streaming = ScreenView.streamingInputs(camera: camera, groundHeight: inputs.terrainHeight,
                                                   fieldOfView: cameraFieldOfView ?? .pi / 4, aspect: 1)
        }
        streamingRadius = streaming.streamingRadius
        let lod = streaming.lod
        let toWorld = streaming.anchor.ecefFromAnchor
        let viewerPosition = toWorld.apply(lod.position)
        viewer = Viewpoint(position: plane.point(viewerPosition),
                           direction: plane.direction(toWorld.rotation.act(lod.direction)),
                           fieldOfView: lod.fieldOfView)
        cameraAltitude = camera.height - inputs.terrainHeight
        viewerAltitude = Geodesy.geodetic(viewerPosition).height - inputs.terrainHeight

        // G, and the point placed on C.
        let g: SIMD3<Double>?
        if let framing {
            g = framing.georeferencePoint
        } else if case let .hit(point, _) = Geodesy.intersect(ray: Ray(origin: camera.position,
                                                                        direction: camera.basis.forward),
                                                               surfaceHeight: inputs.terrainHeight) {
            g = point
        } else {
            g = nil
        }
        georeferencePoint = g.map(plane.point)
        placedPoint = framing.map { plane.point($0.georeference.ecef(map: $0.placementPoint)) }

        // Along-track distance: positive ahead of the camera.
        let nadirCoordinate = camera.coordinate
        func track(_ s: Double, height: Double) -> SIMD3<Double> {
            let c = GeoMath.destination(from: nadirCoordinate, bearing: s >= 0 ? camera.heading : camera.heading + .pi,
                                        distance: abs(s))
            return Geodesy.ecef(c, height: height)
        }
        func alongTrack(_ point: SIMD3<Double>) -> Double {
            let d = GeoMath.distance(from: nadirCoordinate, to: Geodesy.geodetic(point).coordinate)
            return plane.point(point).x >= 0 ? d : -d
        }
        let halfTurn = Double.pi * GeoMath.earthRadius
        /// Along-track distances across `centre` ± `radius`, within a half turn.
        func span(_ centre: Double, _ radius: Double, count: Int = 64) -> [Double] {
            Self.samples(from: max(centre - radius, -halfTurn), to: min(centre + radius, halfTurn), count: count)
        }
        let gDistance = g.map(alongTrack) ?? 0
        rangeToGeoreference = g.map { simd_distance($0, camera.position) }
        groundDistanceToGeoreference = g.map { _ in gDistance }
        let groundRadius = GeoMath.earthRadius + inputs.terrainHeight
        horizonDistance = groundRadius * acos(min(groundRadius / (groundRadius + max(cameraAltitude, 0)), 1))
        horizonPoint = plane.point(track(horizonDistance, height: inputs.terrainHeight))
        let areaDistance = alongTrack(streaming.anchor.ecefFromAnchor.translation)
        streamedArea = span(areaDistance, streamingRadius).map {
            plane.point(track($0, height: inputs.terrainHeight))
        }

        let room = inputs.presentation.room
        let rho = framing.flatMap { f in room.map { f.shownRadius($0) } }
        shownRadius = rho
        scale = framing?.georeference.scale
        if let rho, g != nil {
            shownRegion = span(gDistance, rho).map { plane.point(track($0, height: ground)) }
        } else {
            shownRegion = []
        }
        earthCentre = plane.point(.zero)

        var key = [self.camera.position, viewer.position, SIMD2(0, inputs.terrainHeight)]
        // Tilting up, G slides out to the horizon; past it, frame on the
        // horizon so the view doesn't jump when the ray stops hitting.
        key += [georeferencePoint ?? horizonPoint, placedPoint].compactMap { $0 }
        if let first = shownRegion.first, let last = shownRegion.last { key += [first, last] }
        let worldBounds = Bounds(key).padded(0.2, minimumSize: max(40, 0.1 * abs(cameraAltitude)))
        self.worldBounds = worldBounds

        // Surfaces, sampled across what the world view shows and around
        // what the room shows.
        let worldFrom = max(worldBounds.min.x - worldBounds.size.x, -halfTurn)
        let worldTo = min(worldBounds.max.x + worldBounds.size.x, halfTurn)
        let closes = worldFrom <= -halfTurn && worldTo >= halfTurn
        let roomRange = rho.map { rho in
            (max(min(0, gDistance) - 3 * rho, -halfTurn), min(max(0, gDistance) + 3 * rho, halfTurn))
        }
        var kinds: [(Surface.Kind, Double)] = [(.ellipsoid, 0), (.terrain, inputs.terrainHeight)]
        if inputs.presentation.room != nil { kinds.append((.placementGround, ground)) }
        surfaces = kinds.map { kind, height in
            let world = Self.samples(from: worldFrom, to: worldTo, count: 480).map { plane.point(track($0, height: height)) }
            var placed: [SIMD2<Double>] = []
            if let framing, let roomRange {
                placed = Self.samples(from: roomRange.0, to: roomRange.1, count: 400).map {
                    Self.side(framing.georeference.map(track($0, height: height)))
                }
            }
            return Surface(kind: kind, height: height, world: world, room: placed, closesWorld: closes)
        }

        if let framing, let room {
            let eye = Self.side(room.designEye)
            let placement = Self.side(framing.placementPoint)
            let container = inputs.containerSize.map { size in
                Bounds([SIMD2(-size.z / 2, -size.y / 2), SIMD2(size.z / 2, size.y / 2)])
            }
            let level = Self.side(room.placementLevel)
            let roomCamera = Self.side(framing.georeference.map(camera.position))
            let centre = Self.side(room.contentCentre(tiltWeight: weight))
            var points = [eye, level, Self.side(room.placementDown), placement, roomCamera,
                          level - SIMD2(room.contentHalfWidth, 0), level + SIMD2(room.contentHalfWidth, 0)]
            if let container { points += [container.min, container.max] }
            self.room = Room(eye: eye, levelPlacement: level, downPlacement: Self.side(room.placementDown),
                             contentCentre: centre, placement: placement, camera: roomCamera,
                             tilt: weight * room.fullTilt, basePlaneHeight: room.placementLevel.y,
                             contentHalfWidth: room.contentHalfWidth, container: container,
                             lod: Viewpoint(position: eye, direction: simd_normalize(placement - eye),
                                            fieldOfView: lod.fieldOfView),
                             earthCentre: Self.side(framing.georeference.map(.zero)),
                             streamedArea: span(areaDistance, streamingRadius, count: 200).map {
                                 Self.side(framing.georeference.map(track($0, height: inputs.terrainHeight)))
                             },
                             bounds: Bounds(points).padded(0.15, minimumSize: 0.5))
        } else {
            self.room = nil
        }
    }

    /// Map frame → room side view: x away from the viewer, y up.
    static func side(_ p: SIMD3<Double>) -> SIMD2<Double> { SIMD2(-p.z, p.y) }

    private static func samples(from a: Double, to b: Double, count: Int) -> [Double] {
        (0..<count).map { a + (b - a) * Double($0) / Double(count - 1) }
    }
}
