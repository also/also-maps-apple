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
            applySettings()
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
    private var dragStartFocus: (east: Double, north: Double)?
    private var magnifyStartRadius: Double?

    private var focusEast = 0.0
    private var focusNorth = 0.0
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
        gestureTarget.components.set(InputTargetComponent())
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

    /// Size the gesture box to the presented map: the volume's box, magnified,
    /// standing on the ground point.
    private func layOutGestureTarget() {
        let size = SIMD3<Float>(Self.volumeSize * presentation.magnification)
        gestureTarget.components.set(CollisionComponent(shapes: [.generateBox(size: size)]))
        gestureTarget.position = presentation.groundPosition + [0, size.y / 2, 0]
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

        let streamer = CNTileStreamer(tilesetURL: url,
                                      originLatitude: location.latitude,
                                      longitude: location.longitude,
                                      height: 0)
        self.streamer = streamer
        applySettings()
        applyFocus()
        sampleGround()
    }

    // MARK: Gestures

    /// `translation` is the drag in scene metres since the gesture began.
    func drag(translation: SIMD3<Float>) {
        if dragStartFocus == nil { dragStartFocus = (focusEast, focusNorth) }
        guard let start = dragStartFocus else { return }
        let local = sceneToLocal(SIMD2(Double(translation.x), Double(translation.z)))
        let metresPerScene = 1 / sceneScale
        // Content follows the hand: dragging right reveals what's to the left.
        focusEast = start.east - local.x * metresPerScene
        // Local +z is south, so dragging toward you reveals what's ahead.
        focusNorth = start.north + local.y * metresPerScene
        applyFocus()
    }

    func endDrag() {
        dragStartFocus = nil
        sampleGround()
    }

    func magnify(by magnification: Double) {
        if magnifyStartRadius == nil { magnifyStartRadius = radius }
        guard let start = magnifyStartRadius, magnification > 0 else { return }
        radius = min(max(start / magnification, 50), 20_000)
        applyFocus()
    }

    func endMagnify() {
        magnifyStartRadius = nil
        // The sampled region grows and shrinks with the radius.
        sampleGround()
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
        for tile in frame.tilesToRender {
            visible.insert(tile.identifier)
            if tileEntities[tile.identifier] == nil, Date() < deadline {
                let entity = Self.makeEntity(for: tile)
                tileEntities[tile.identifier] = entity
                tilesRoot.addChild(entity)
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
            print("[MapVolume] render \(frame.tilesToRender.count) tiles, \(tileEntities.count) entities, progress \(Int(frame.loadProgress))%, focus height \(Int(focusHeight)) m")
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
            heading += input.turn * boost * (.pi / 3) * deltaTime  // 60°/s
            heading = heading.truncatingRemainder(dividingBy: 2 * .pi)
        }
        if input.zoom != 0 {
            radius = min(max(radius * exp(-input.zoom * boost * deltaTime), 50), 20_000)
        }
        if input.move != .zero {
            // Scene-relative: forward is away from the viewer (−z), right is +x.
            let local = sceneToLocal(SIMD2(input.move.x, -input.move.y))
            // Cross most of the visible region per second at any zoom.
            let metres = radius * 0.8 * boost * deltaTime
            focusEast += local.x * metres
            focusNorth -= local.y * metres
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
        streamer.focusEast = focusEast
        streamer.focusNorth = focusNorth
        streamer.focusHeight = focusHeight
        streamer.focusRadius = radius
        // Only the floor modes stream past the volume-sized square; the volume
        // would clip the extra away anyway.
        streamer.streamingRadius = presentation.host == .immersive ? radius * settings.immersiveRegion : 0
        streamer.viewerDistance = Self.viewerDistanceInScene / streamingScale
        streamer.viewHeading = heading

        // Tiles are baked in the origin's local frame (x east, y up, z south).
        // Turn the map about the vertical by the heading, then place the
        // focus point on the presentation's ground point.
        let s = Float(sceneScale)
        let rotation = simd_quatf(angle: Float(heading), axis: [0, 1, 0])
        let focusLocal = SIMD3<Float>(Float(focusEast), Float(focusHeight), Float(-focusNorth))
        tilesRoot.scale = SIMD3(repeating: s)
        tilesRoot.orientation = rotation
        tilesRoot.position = presentation.groundPosition - rotation.act(focusLocal * s)
    }

    private func applySettings() {
        guard let streamer else { return }
        streamer.maximumScreenSpaceError = settings.detail
        streamer.culledScreenSpaceError = settings.outerDetail
        streamer.maximumSimultaneousTileLoads = Int(settings.simultaneousLoads)
        streamer.maximumCachedBytes = Int64(settings.cacheMegabytes * 1024 * 1024)
        streamer.forbidHoles = settings.forbidHoles
    }

    private func sampleGround() {
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
