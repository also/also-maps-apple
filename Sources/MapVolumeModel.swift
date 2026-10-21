import Foundation
import Observation
import RealityKit
import SwiftUI
import UIKit

/// Owns the cesium-native streamer and mirrors its selected tiles as
/// RealityKit entities under `root`.
@MainActor
@Observable
final class MapVolumeModel {
    /// Volume extents in metres (width, height, depth).
    static let volumeSize = SIMD3<Double>(1.0, 0.6, 1.0)
    /// How far a typical viewer stands from the volume; drives LOD.
    private static let viewerDistanceInScene = 1.2

    struct Location {
        var latitude: Double
        var longitude: Double
        var radius: Double
    }

    static let defaultLocation = Location(latitude: 37.7955, longitude: -122.3937, radius: 600)

    /// The whole map: tiles plus the gesture target. Lives under whichever
    /// host's anchor matches the current presentation.
    let root = Entity()
    /// Invisible box that receives drag / magnify gestures.
    let gestureTarget = Entity()

    var settings = StreamingSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if radius != clampRadius(radius) {
                radius = clampRadius(radius)
                sampleGround()
            }
            applySettings()
            layOutGestureTarget()
            applyFocus()
        }
    }

    struct Stats: Equatable {
        var renderedTiles = 0
        var entities = 0
    }
    private(set) var stats = Stats()

    var presentation = MapPresentation.volume {
        didSet {
            guard presentation != oldValue else { return }
            reparentRoot()
            layOutGestureTarget()
            applyFocus()
        }
    }

    private(set) var credits: [String] = []
    private(set) var loadProgress: Float = 0
    private(set) var statusMessage: String?
    private(set) var keyboardConnected = false
    /// Whether the volume (map + controls) window is open. In a floor mode
    /// it can be closed while the immersive space stays up.
    var volumeIsOpen = false

    private var streamer: CNTileStreamer?
    private let tilesRoot = Entity()
    private var tileEntities: [UInt64: Entity] = [:]
    /// One anchor per host scene; `root` moves between them.
    private var anchors: [MapPresentation.Host: Entity] = [:]
    /// Both scenes deliver frame updates; only the presented host's are used.
    private var updateSubscriptions: [MapPresentation.Host: EventSubscription] = [:]
    private var debugLogElapsed: Float = 0

    // Gesture state.
    private var dragStartFocus: GeoCoordinate?
    /// Identifies the drag in progress. visionOS can cancel a gesture without
    /// calling onEnded, so a new start location means a new drag.
    private var dragStartLocation: SIMD3<Float>?
    private var lastMagnifyUpdate = Date.distantPast
    private var rotateStartHeading: Double?
    private var rotateStartLocation: SIMD3<Float>?
    private var magnifyStartRadius: Double?

    /// Centre of the view. Kept as latitude/longitude and moved along the
    /// globe, so steering stays true however far it gets from the start.
    private var focus = GeoCoordinate(latitude: defaultLocation.latitude, longitude: defaultLocation.longitude)
    private var focusHeight = 0.0
    /// Where focusHeight is easing toward; set by the latest ground sample.
    private var targetFocusHeight: Double?
    /// Bumped per sample request so a slow, older result can't win.
    private var groundSampleGeneration = 0
    private var radius = defaultLocation.radius
    /// Compass bearing the volume's front faces, radians clockwise from north.
    private var heading = 0.0
    private var keyboardWasActive = false

    init() {
        root.addChild(tilesRoot)
        // Indirect only (look + pinch). Allowing direct input meant hands that
        // were merely inside the map's area counted as touching it and
        // dragged the map with no pinch at all.
        gestureTarget.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        root.addChild(gestureTarget)
        layOutGestureTarget()
    }

    /// Called from each host's RealityView. Adds that host's anchor, routes
    /// its frame updates here, and starts streaming the first time.
    func attach(_ content: RealityViewContent, host: MapPresentation.Host) {
        let anchor = Entity()
        anchor.name = "anchor-\(host)"
        content.add(anchor)
        anchors[host] = anchor
        updateSubscriptions[host] = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.presentation.host == host else { return }
                self.tick(deltaTime: Float(event.deltaTime))
            }
        }
        reparentRoot()
        start()
    }

    /// The immersive space went away (dismissed by us or the system).
    func immersiveSpaceDidClose() {
        anchors[.immersive] = nil
        updateSubscriptions[.immersive] = nil
        if presentation.host == .immersive { presentation = .volume }
    }

    private func reparentRoot() {
        if let anchor = anchors[presentation.host], root.parent !== anchor {
            anchor.addChild(root)
        }
    }

    /// The gesture target is a thin slab at ground level covering the
    /// streamed square. Gaze passes through terrain and buildings (they have no
    /// collision) to the slab, while looking past the map's edges or over it
    /// no longer hits an invisible box.
    private func layOutGestureTarget() {
        let region = presentation.host == .immersive ? settings.immersiveRegion : 1
        let width = Float(Self.volumeSize.x * presentation.magnification * region)
        let thickness = Float(0.02 * presentation.magnification)
        gestureTarget.components.set(CollisionComponent(shapes: [
            .generateBox(size: [width, thickness, width])
        ]))
        gestureTarget.position = presentation.groundPosition
    }

    private func start() {
        guard streamer == nil, statusMessage == nil else { return }

        // Debug overrides: MAPVOLUME_LAT/_LON/_RADIUS pick the starting view, and
        // MAPVOLUME_TILESET_URL streams any 3D Tiles tileset instead of
        // Google's, no key needed.
        let env = ProcessInfo.processInfo.environment
        var location = Self.defaultLocation
        location.latitude = env["MAPVOLUME_LAT"].flatMap(Double.init) ?? location.latitude
        location.longitude = env["MAPVOLUME_LON"].flatMap(Double.init) ?? location.longitude
        location.radius = env["MAPVOLUME_RADIUS"].flatMap(Double.init) ?? location.radius
        heading = (env["MAPVOLUME_HEADING"].flatMap(Double.init) ?? 0) * .pi / 180
        // Start the focus away from the tileset origin, e.g. to check curvature.
        focus = GeoMath.offset(GeoCoordinate(latitude: location.latitude, longitude: location.longitude),
                               east: (env["MAPVOLUME_FOCUS_EAST_KM"].flatMap(Double.init) ?? 0) * 1000,
                               north: (env["MAPVOLUME_FOCUS_NORTH_KM"].flatMap(Double.init) ?? 0) * 1000)
        let url: String
        if let override = env["MAPVOLUME_TILESET_URL"], !override.isEmpty {
            url = override
        } else if let key = Self.apiKey() {
            url = "https://tile.googleapis.com/v1/3dtiles/root.json?key=\(key)"
        } else {
            statusMessage = "Set GOOGLE_MAPS_API_KEY in Config/Secrets.xcconfig (or the scheme environment)."
            return
        }
        radius = location.radius

        let streamer = CNTileStreamer(tilesetURL: url)
        self.streamer = streamer
        applySettings()
        applyFocus()
        sampleGround()
    }

    // MARK: Gestures

    /// `start` and `current` are the drag's scene positions, in metres.
    func drag(from start: SIMD3<Float>, to current: SIMD3<Float>) {
        if dragStartLocation != start {
            dragStartLocation = start
            dragStartFocus = focus
        }
        let translation = current - start
        guard let startFocus = dragStartFocus else { return }
        let local = sceneToLocal(SIMD2(Double(translation.x), Double(translation.z)))
        let metresPerScene = 1 / sceneScale
        // Content follows the hand: dragging right reveals what's to the left,
        // and (local +z being south) dragging toward you reveals what's ahead.
        focus = GeoMath.offset(startFocus,
                               east: -local.x * metresPerScene,
                               north: local.y * metresPerScene)
        applyFocus()
    }

    func endDrag() {
        dragStartFocus = nil
        dragStartLocation = nil
        sampleGround()
    }

    func magnify(by magnification: Double) {
        // As with drag, a cancelled pinch never reaches endMagnify; a pause in
        // updates means this is a new pinch.
        if magnifyStartRadius == nil || Date().timeIntervalSince(lastMagnifyUpdate) > 0.3 {
            magnifyStartRadius = radius
        }
        lastMagnifyUpdate = Date()
        guard let start = magnifyStartRadius, magnification > 0 else { return }
        radius = clampRadius(start / magnification)
        updateCurvatureAnchor()
        applyFocus()
    }

    func endMagnify() {
        magnifyStartRadius = nil
        // The sampled region grows and shrinks with the radius.
        sampleGround()
    }

    /// `rotation` is the two-handed twist since the gesture began, already in
    /// scene space. The map follows the hands, turning about its focus point.
    func rotate(by rotation: simd_quatf, startedAt start: SIMD3<Float>) {
        if rotateStartLocation != start {
            rotateStartLocation = start
            rotateStartHeading = heading
        }
        guard let startHeading = rotateStartHeading else { return }
        // Signed angle about +Y (counterclockwise seen from above), which is
        // the same sense as the map's heading rotation.
        let yaw = 2 * atan2(Double(rotation.imag.y), Double(rotation.real))
        heading = (startHeading + yaw).truncatingRemainder(dividingBy: 2 * .pi)
        applyFocus()
    }

    func endRotate() {
        rotateStartHeading = nil
        rotateStartLocation = nil
    }

    // MARK: Frame loop

    private func tick(deltaTime: Float) {
        guard let streamer else { return }
        applyKeyboard(deltaTime: Double(deltaTime))
        easeFocusHeight(deltaTime: Double(deltaTime))
        let frame = streamer.update(withDeltaTime: deltaTime)

        for id in frame.freedTileIDs {
            tileEntities.removeValue(forKey: id.uint64Value)?.removeFromParent()
        }

        let deadline = Date().addingTimeInterval(settings.uploadBudgetMilliseconds / 1000)
        var visible = Set<UInt64>()
        frame.tileTransforms.withUnsafeBytes { buffer in
            let placements = buffer.bindMemory(to: simd_float4x4.self)
            for (index, tile) in frame.tilesToRender.enumerated() {
                visible.insert(tile.identifier)
                if tileEntities[tile.identifier] == nil, Date() < deadline {
                    let entity = Self.makeEntity(for: tile)
                    tileEntities[tile.identifier] = entity
                    tilesRoot.addChild(entity)
                }
                // Placed relative to the current focus every frame, so there's
                // no fixed origin for precision to drift away from.
                tileEntities[tile.identifier]?.transform = Transform(matrix: placements[index])
            }
        }
        for (id, entity) in tileEntities {
            entity.isEnabled = visible.contains(id)
        }

        if credits != frame.credits { credits = frame.credits }
        loadProgress = frame.loadProgress
        let newStats = Stats(renderedTiles: frame.tilesToRender.count, entities: tileEntities.count)
        if stats != newStats { stats = newStats }

        #if DEBUG
        debugLogElapsed += deltaTime
        if debugLogElapsed > 1 {
            debugLogElapsed = 0
            print("[MapVolume] render \(frame.tilesToRender.count) tiles, \(tileEntities.count) entities, progress \(Int(frame.loadProgress))%, focus \(String(format: "%.4f, %.4f", focus.latitude, focus.longitude)), height \(Int(focusHeight)) m")
        }
        #endif
    }

    // MARK: Keyboard

    private func applyKeyboard(deltaTime: Double) {
        let connected = KeyboardInput.isKeyboardConnected
        if keyboardConnected != connected { keyboardConnected = connected }

        let input = KeyboardInput.current()
        guard input.isActive else {
            // Re-sample once movement settles, like the end of a drag.
            if keyboardWasActive {
                keyboardWasActive = false
                sampleGround()
            }
            return
        }
        keyboardWasActive = true
        let boost = input.fast ? 3.0 : 1.0

        if input.turn != 0 {
            let newHeading = (heading + input.turn * boost * (.pi / 3) * deltaTime)  // 60°/s
                .truncatingRemainder(dividingBy: 2 * .pi)
            if settings.keyboardTurnPivot == .frontEdge {
                // Keep the middle of the near edge fixed: it sits `radius`
                // behind the focus, so swing the focus around it by the turn.
                let back = GeoMath.destination(from: focus, bearing: heading + .pi, distance: radius)
                let outward = GeoMath.bearing(from: back, to: focus)
                focus = GeoMath.destination(from: back, bearing: outward + (newHeading - heading), distance: radius)
            }
            heading = newHeading
        }
        if input.zoom != 0 {
            radius = clampRadius(radius * exp(-input.zoom * boost * deltaTime))
            updateCurvatureAnchor()
        }
        if input.move != .zero {
            // Scene-relative: forward is away from the viewer (−z), right is +x.
            let local = sceneToLocal(SIMD2(input.move.x, -input.move.y))
            // Cross most of the visible region per second at any zoom.
            let metres = radius * 0.8 * boost * deltaTime
            focus = GeoMath.offset(focus, east: local.x * metres, north: -local.y * metres)
        }
        applyFocus()
    }

    // MARK: Helpers

    /// Rotates a horizontal scene-space vector (x, z) into the tiles' local
    /// frame (x east, z south), undoing the map's heading rotation.
    private func sceneToLocal(_ v: SIMD2<Double>) -> SIMD2<Double> {
        let c = cos(heading), s = sin(heading)
        return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    /// Scene metres per world metre as the volume shows it. Streaming always
    /// uses this, so every presentation gets the same tiles at the same detail.
    private var streamingScale: Double { (Self.volumeSize.x / 2) / radius }

    /// Scene metres per world metre as currently displayed.
    private var sceneScale: Double { streamingScale * presentation.magnification }

    private func applyFocus() {
        guard let streamer else { return }
        streamer.focusLatitude = focus.latitude
        streamer.focusLongitude = focus.longitude
        streamer.focusHeight = focusHeight
        streamer.focusRadius = radius
        // Only the floor modes stream past the volume-sized square; the volume
        // would clip the extra away anyway.
        streamer.streamingRadius = presentation.host == .immersive ? radius * settings.immersiveRegion : 0
        streamer.viewerDistance = Self.viewerDistanceInScene / streamingScale
        streamer.viewHeading = heading

        // Each tile entity is placed by the streamer in the focus's level
        // frame (x east, y up, z south, focus ground point at 0). Here that
        // frame is turned by the heading, scaled, and set on the
        // presentation's ground point.
        let s = Float(sceneScale)
        let rotation = simd_quatf(angle: Float(heading), axis: [0, 1, 0])
        let placement = Transform(scale: SIMD3(repeating: s),
                                  rotation: rotation,
                                  translation: presentation.groundPosition)
        tilesRoot.transform = placement
        gestureTarget.orientation = rotation
    }

    private func applySettings() {
        guard let streamer else { return }
        streamer.maximumScreenSpaceError = settings.detail
        streamer.culledScreenSpaceError = settings.outerDetail
        streamer.maximumSimultaneousTileLoads = Int(settings.simultaneousLoads)
        streamer.maximumCachedBytes = Int64(settings.cacheMegabytes * 1024 * 1024)
        streamer.forbidHoles = settings.forbidHoles
    }

    private func clampRadius(_ value: Double) -> Double {
        min(max(value, 50), settings.zoomOutLimitKilometres * 1000)
    }

    /// Above this half-width the Earth's curve, not the terrain, decides
    /// where the ground should sit: the edges fall away by ~200 m at 50 km.
    private static let curvatureAnchorRadius = 50_000.0
    private static let earthRadius = 6_371_000.0

    /// How far the surface at the view's edge (`radius` from the focus) falls
    /// below the focus's level plane, capped at a hemisphere.
    private func curvatureDrop() -> Double {
        let angle = min(radius / Self.earthRadius, .pi / 2)
        return Self.earthRadius * (1 - cos(angle))
    }

    /// Zoomed out past curvatureAnchorRadius, anchor on the curve instead of
    /// sampling: lift the map so sea level at the view's edges meets the
    /// floor. Cheap enough to follow the zoom continuously.
    private func updateCurvatureAnchor() {
        guard radius >= Self.curvatureAnchorRadius else { return }
        groundSampleGeneration += 1  // Discard any sample still in flight.
        targetFocusHeight = -curvatureDrop()
    }

    private func sampleGround() {
        if radius >= Self.curvatureAnchorRadius {
            updateCurvatureAnchor()
            return
        }
        groundSampleGeneration += 1
        let generation = groundSampleGeneration
        streamer?.sampleGroundHeightInFocusRegion { [weak self] height in
            MainActor.assumeIsolated {
                guard let self, height.isFinite,
                      generation == self.groundSampleGeneration else { return }
                #if DEBUG
                print("[MapVolume] ground sample \(Int(height)) m (was \(Int(self.focusHeight)) m)")
                #endif
                self.targetFocusHeight = height
            }
        }
    }

    /// Glides the ground plane to the latest sample instead of snapping, so a
    /// re-sample after a pan reads as the terrain settling rather than a jump.
    private func easeFocusHeight(deltaTime: Double) {
        guard let target = targetFocusHeight else { return }
        let remaining = target - focusHeight
        if abs(remaining) * sceneScale < 0.0005 {
            focusHeight = target
            targetFocusHeight = nil
        } else {
            // Exponential approach: about 95% of the way in half a second.
            focusHeight += remaining * min(1, deltaTime * 6)
        }
        applyFocus()
    }

    private static func apiKey() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["GOOGLE_MAPS_API_KEY"],
            Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String,
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("$(") && $0 != "YOUR_KEY_HERE" }
    }

    private static func makeEntity(for tile: CNTileMesh) -> Entity {
        let entity = Entity()
        for primitive in tile.primitives ?? [] {
            do {
                entity.addChild(try makeModel(for: primitive))
            } catch {
                print("[MapVolume] tile \(tile.identifier) primitive failed: \(error)")
            }
        }
        tile.discardCPUData()
        return entity
    }

    private static func makeModel(for primitive: CNPrimitive) throws -> ModelEntity {
        var descriptor = MeshDescriptor(name: "tile")
        descriptor.positions = MeshBuffer(primitive.positions.withUnsafeBytes {
            Array($0.bindMemory(to: SIMD3<Float>.self))
        })
        if let texcoords = primitive.texcoords {
            descriptor.textureCoordinates = MeshBuffer(texcoords.withUnsafeBytes {
                Array($0.bindMemory(to: SIMD2<Float>.self))
            })
        }
        descriptor.primitives = .triangles(primitive.indices.withUnsafeBytes {
            Array($0.bindMemory(to: UInt32.self))
        })
        let mesh = try MeshResource.generate(from: [descriptor])

        var material = UnlitMaterial()
        material.faceCulling = .none
        if let rgba = primitive.rgba, let image = makeImage(rgba: rgba,
                                                            width: primitive.textureWidth,
                                                            height: primitive.textureHeight) {
            let texture = try TextureResource.generate(from: image,
                                                       options: .init(semantic: .color))
            material.color = .init(tint: .white, texture: .init(texture))
        } else {
            material.color = .init(tint: .gray)
        }
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private static func makeImage(rgba: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
