import Foundation
import Observation
import RealityKit
import UIKit

/// The world in miniature: while the immersive space is open, the volume
/// shows a tabletop copy of the world around you (MiniatureLayout), with a
/// marker for your eye, your heading and where you're looking, and the
/// outline of what the immersive map streams. Pinch-tap it to go somewhere;
/// drag it to slide along; pinch with both hands to zoom it.
///
/// Its tiles come from a second streamer of its own. A RealityKit entity can
/// only be in one scene, and the immersive map's tiles are the wrong detail
/// anyway (fine around you, coarse or missing tens of kilometres away), and
/// aren't RealityKit entities at all with the Metal renderer. The streamer
/// exists only while the miniature is shown, so nothing streams or stays in
/// memory otherwise; each start is a new root tileset request, which Google
/// counts as a map session. See notes/world-in-miniature.md.
@MainActor
@Observable
final class WorldMiniature {
    /// Goes in the volume's scene, at its origin: the table frame is the
    /// volume's scene space.
    @ObservationIgnored let root = Entity()
    /// The table's surface, for tap, drag and pinch. Tiles have no
    /// collision, so gaze passes through terrain to it.
    @ObservationIgnored let gestureTarget = Entity()

    /// Size and orientation; adjustable while shown.
    var layout = MiniatureLayout()

    /// The miniature's own tiles, while it's shown.
    private(set) var streaming: TileStreaming? = nil
    var isShown: Bool { streaming != nil }

    /// The last placement, for turning table points back into places.
    @ObservationIgnored private var georeference: Georeference? = nil

    @ObservationIgnored private let markers = Entity()
    @ObservationIgnored private let eye: ModelEntity
    @ObservationIgnored private let post: ModelEntity
    @ObservationIgnored private let headingBar: ModelEntity
    @ObservationIgnored private let viewCone: ModelEntity
    @ObservationIgnored private let outlineBars: [ModelEntity]

    /// Debug: ALSOMAPS_MINIATURE_DETAIL=<SSE> sets the miniature's detail.
    private static let detail: Double = {
        let value = ProcessInfo.processInfo.environment["ALSOMAPS_MINIATURE_DETAIL"].flatMap(Double.init)
        return min(max(value ?? 24, 2), 256)
    }()

    init() {
        func model(_ mesh: MeshResource, _ color: UIColor, opacity: Float = 1) -> ModelEntity {
            var material = UnlitMaterial(color: color)
            material.faceCulling = .none
            if opacity < 1 {
                // UNVERIFIED: UnlitMaterial.blending and Opacity's float
                // literal, as on PhysicallyBasedMaterial.
                material.blending = .transparent(opacity: .init(floatLiteral: opacity))
            }
            return ModelEntity(mesh: mesh, materials: [material])
        }
        let bar = MeshResource.generateBox(size: 1)
        eye = model(.generateSphere(radius: 0.008), .white)
        post = model(bar, .white)
        headingBar = model(bar, .systemOrange)
        viewCone = model(Self.cone(), .systemTeal, opacity: 0.35)
        outlineBars = (0..<4).map { _ in model(bar, .systemYellow) }
        for entity in [eye, post, headingBar, viewCone] + outlineBars {
            markers.addChild(entity)
        }
        root.addChild(markers)

        // A thin slab over the table, at the ground's level. Indirect only,
        // like the map's: hands merely inside the volume mustn't move you.
        let table = Float(2 * layout.tableHalfWidth)
        gestureTarget.components.set(CollisionComponent(shapes: [.generateBox(size: [table, 0.01, table])]))
        gestureTarget.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        gestureTarget.position = SIMD3<Float>(layout.tableGround)
        root.addChild(gestureTarget)
        root.isEnabled = false
    }

    /// The miniature's streaming settings: the main map's tile source, a
    /// coarser detail and a smaller budget than the immersive map's, since
    /// it's a 1 m table and runs beside it.
    static func streamingSettings(tileSource: TileSource) -> StreamingSettings {
        var settings = StreamingSettings.default
        settings.tileSource = tileSource
        settings.detail = detail
        // Everything on the table is inside the LOD camera's view.
        settings.outerDetail = max(detail, 64)
        settings.uploadConcurrency = 4
        settings.simultaneousLoads = 16
        settings.cacheMegabytes = 128
        settings.forbidHoles = true
        return settings
    }

    /// Shows or hides the miniature. Showing starts its streamer around
    /// `centre`; hiding drops the streamer and every tile it loaded.
    func setShown(_ shown: Bool, tileSource: TileSource, centre: GeoCoordinate) {
        if shown {
            if let streaming {
                // A new source restarts it (TileStreaming does that itself).
                if streaming.settings.tileSource != tileSource {
                    streaming.settings = Self.streamingSettings(tileSource: tileSource)
                }
            } else {
                let streaming = TileStreaming(inputs: StreamingInputs(anchor: StreamingAnchor(coordinate: centre)),
                                              settings: Self.streamingSettings(tileSource: tileSource),
                                              name: "miniature")
                root.addChild(streaming.tilesRoot)
                streaming.start()
                self.streaming = streaming
            }
            if !root.isEnabled { root.isEnabled = true }
        } else if let streaming {
            streaming.tilesRoot.removeFromParent()
            self.streaming = nil
            georeference = nil
            root.isEnabled = false
        }
    }

    /// One frame: follows the camera (the eye) over ground at
    /// `groundHeight`, draws where you're looking (`viewDirection`, ECEF,
    /// or the camera's heading without one) and the main map's streamed
    /// square (`main`), and runs the miniature's streamer.
    func update(camera: CameraPose, groundHeight: Double, viewDirection: SIMD3<Double>?,
                main: StreamingInputs, deltaTime: Float) {
        guard let streaming else { return }
        let georeference = layout.georeference(centre: camera.coordinate, groundHeight: groundHeight,
                                               cameraHeading: camera.heading)
        self.georeference = georeference
        streaming.inputs = layout.streamingInputs(centre: camera.coordinate, groundHeight: groundHeight,
                                                  cameraHeading: camera.heading)
        // The tiles' frame, composed in double like the main map's.
        streaming.tilesRoot.transform = Transform(georeference.placement(of: streaming.inputs.anchor))
        streaming.update(deltaTime: deltaTime)
        updateMarkers(camera: camera, groundHeight: groundHeight, viewDirection: viewDirection,
                      main: main, georeference: georeference)
    }

    /// The place under a point on the table (the volume's scene space), or
    /// nil if it's off the table or nothing is shown yet.
    func coordinate(atScene point: SIMD3<Float>) -> GeoCoordinate? {
        guard let georeference else { return nil }
        let table = SIMD3<Double>(point)
        guard layout.isOnTable(table) else { return nil }
        return layout.coordinate(atTable: table, georeference: georeference)
    }

    /// The ground at `coordinate` from the miniature's own tiles, for a
    /// first guess before the main map has sampled there: the lowest vertex
    /// of the most detailed tile over it, or nil if none is. Coarse, and only
    /// ever used while rendering, never stored.
    func groundHeight(at coordinate: GeoCoordinate) -> Double? {
        streaming.flatMap { GroundEstimates.columnHeight($0.renderedHeightRanges(), at: coordinate) }
    }

    // MARK: Markers

    private func updateMarkers(camera: CameraPose, groundHeight: Double, viewDirection: SIMD3<Double>?,
                               main: StreamingInputs, georeference: Georeference) {
        let marker = layout.marker(camera: camera, groundHeight: groundHeight, georeference: georeference)
        let eyePoint = SIMD3<Float>(marker.eye)
        eye.position = eyePoint
        // A post from the ground up to the eye, so its height reads, and so
        // an eye drawn at the ceiling still shows where it is.
        TileBoundsOverlay.place(post, SIMD3<Float>(marker.nadir), eyePoint, marker.isClamped ? 0.0025 : 0.0012)
        TileBoundsOverlay.place(headingBar, eyePoint, eyePoint + 0.04 * SIMD3<Float>(marker.heading), 0.002)

        // Where you're looking: the head's direction if it's tracked,
        // otherwise level along the camera's heading.
        let look = viewDirection.flatMap { layout.tableDirection($0, georeference: georeference) } ?? marker.heading
        let direction = simd_normalize(SIMD3<Float>(look))
        if direction.x.isFinite, direction.y.isFinite, direction.z.isFinite {
            let length: Float = 0.07
            // About the half-angle of the display's field of view.
            let radius = length * tan(Float(35) * .pi / 180)
            viewCone.isEnabled = true
            viewCone.transform = Transform(scale: [radius, radius, length],
                                           rotation: simd_quatf(from: [0, 0, -1], to: direction),
                                           translation: eyePoint)
        } else {
            viewCone.isEnabled = false
        }

        // The main map's streamed square, just above the table's ground so
        // it doesn't fight the tiles there. Often bigger than the table
        // (streaming reaches the horizon unless reach is limited), and then
        // the volume clips it.
        let outline = layout.streamedOutline(main, georeference: georeference).map {
            SIMD3<Float>($0) + [0, 0.004, 0]
        }
        for i in 0..<4 {
            TileBoundsOverlay.place(outlineBars[i], outline[i], outline[(i + 1) % 4], 0.0015)
        }
    }

    /// A cone along −z from its apex at the origin to a unit circle at
    /// z = −1, open at the far end.
    private static func cone() -> MeshResource {
        let segments = 24
        var positions: [SIMD3<Float>] = [.zero]
        for i in 0..<segments {
            let angle = Float(i) / Float(segments) * 2 * .pi
            positions.append([cos(angle), sin(angle), -1])
        }
        var indices: [UInt32] = []
        for i in 0..<UInt32(segments) {
            indices += [0, 1 + i, 1 + (i + 1) % UInt32(segments)]
        }
        var descriptor = MeshDescriptor(name: "cone")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generateSphere(radius: 0.5)
    }
}
