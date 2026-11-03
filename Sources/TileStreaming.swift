import Foundation
import OSLog
import Observation
import RealityKit

/// Streams a tile source through cesium-native and mirrors its selected tiles
/// as RealityKit entities under `tilesRoot`. Knows nothing about navigation or
/// presentation: it's told its streaming inputs (anchor, area of interest and
/// LOD camera), and reports what's drawn, the credits to show and how loading
/// is going.
@MainActor
@Observable
final class TileStreaming {
    struct Stats: Equatable {
        var renderedTiles = 0
        var entities = 0
        var cacheHits = 0
        var revalidated = 0
        var networkLoads = 0
        var networkMegabytes = 0.0

        /// Share of requests answered without a full download.
        var cacheHitRate: Double? {
            let total = cacheHits + revalidated + networkLoads
            return total == 0 ? nil : Double(cacheHits + revalidated) / Double(total)
        }

        /// Requests by how they were answered, for the stats overlay.
        var requestsSummary: String {
            String(format: "%d cached · %d revalidated · %d downloaded (%.1f MB)",
                   cacheHits, revalidated, networkLoads, networkMegabytes)
        }
    }

    struct Credit: Hashable {
        var text: String
        /// A provider logo, e.g. Cesium ion's.
        var imageURL: URL?
    }

    /// Holds every tile entity, each placed in the anchor's level frame
    /// (x east, y up, z south, metres, the anchor at 0). The owner places
    /// this in its scene.
    let tilesRoot = Entity()

    var inputs: StreamingInputs {
        didSet { if inputs != oldValue { applyInputs() } }
    }
    /// A different tile source restarts streaming; anything else applies live.
    var settings: StreamingSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.tileSource != oldValue.tileSource {
                restart()
            }
            applySettings()
        }
    }

    private(set) var stats = Stats()
    private(set) var credits: [Credit] = []
    /// Google's terms need its logo shown with its tiles; other sources bring
    /// their own logos in their credits.
    private(set) var showsGoogleLogo = false
    private(set) var loadProgress: Float = 0
    private(set) var statusMessage: String?
    var isStreaming: Bool { streamer != nil }

    private var streamer: CNTileStreamer?
    private let tileUploader = TileUploader()
    /// Builds each tile's renderer resources instead of RealityKit entities
    /// (the macOS Metal spike). Set before `start`; the tiles to draw are then
    /// in `drawnTiles` each frame and nothing is added under `tilesRoot`.
    var customTileHandler: CNTileLoadHandler?
    /// With a custom handler: last frame's tiles, each with its placement in
    /// the anchor's level frame (the same as an entity's under `tilesRoot`).
    private(set) var drawnTiles: [(tile: CNTileMesh, placement: simd_float4x4)] = []
    private var tileEntities: [UInt64: Entity] = [:]
    private var renderedTiles: [CNTileMesh] = []
    /// Draw each drawn tile's bounding box as a wireframe child of the tile:
    /// cyan inside the LOD camera's view, orange outside it.
    var showsTileBounds = false {
        didSet {
            streamer?.reportsTileBounds = showsTileBounds
            if !showsTileBounds { removeTileBoxes() }
        }
    }
    private var tileBoxes: [UInt64: (entity: ModelEntity, inView: Bool)] = [:]
    private let insideViewMaterial = DebugLines.material(red: 0.35, green: 0.78, blue: 0.98)
    private let outsideViewMaterial = DebugLines.material(red: 1, green: 0.62, blue: 0.04)
    private var started = false
    /// The key the streamer was started with.
    private var keyInUse: String?
    private var debugLogElapsed: Float = 0
    /// ALSOMAPS_LOG_STATS=1 prints the streaming stats once a second (Debug
    /// builds); off by default, since Xcode's console quarantines that volume.
    private static let logsStats = ProcessInfo.processInfo.environment["ALSOMAPS_LOG_STATS"] == "1"
    /// Longest main-thread update in the current debug-log second.
    private var debugSlowestUpdate: TimeInterval = 0

    init(inputs: StreamingInputs, settings: StreamingSettings) {
        self.inputs = inputs
        self.settings = settings
    }

    /// Creates the streamer for the current tile source, or explains which
    /// secret is missing. Only the first call does anything.
    func start() {
        guard !started else { return }
        started = true
        startStreamer()
    }

    private func startStreamer() {
        let env = ProcessInfo.processInfo.environment
        let streamer: CNTileStreamer
        showsGoogleLogo = false
        keyInUse = nil
        // Debug: ALSOMAPS_TILESET_URL streams any 3D Tiles tileset, no key.
        if let override = env["ALSOMAPS_TILESET_URL"], !override.isEmpty {
            streamer = CNTileStreamer(tilesetURL: override)
        } else if let assetID = settings.tileSource.ionAssetID {
            guard let token = requireKey(for: .cesiumIon) else { return }
            streamer = CNTileStreamer(ionAssetID: assetID, accessToken: token,
                                      smoothNormals: settings.tileSource.smoothNormals)
        } else {
            guard let key = requireKey(for: .googleMaps) else { return }
            streamer = CNTileStreamer(tilesetURL: "https://tile.googleapis.com/v1/3dtiles/root.json?key=\(key)")
            showsGoogleLogo = true
        }
        statusMessage = nil
        tileUploader.untexturedColor = settings.tileSource.untexturedColor
        // Before the first update, so every tile goes through it.
        streamer.tileLoadHandler = customTileHandler ?? tileUploader.handler
        self.streamer = streamer
        applySettings()
        applyInputs()
    }

    /// Drops everything loaded from the old source and streams the new one
    /// at the same view.
    private func restart() {
        guard started else { return }
        streamer = nil
        for entity in tileEntities.values { entity.removeFromParent() }
        tileEntities = [:]
        tileBoxes = [:]
        renderedTiles = []
        drawnTiles = []
        credits = []
        loadProgress = 0
        stats = Stats()
        startStreamer()
    }

    // MARK: Keys

    /// The service this source needs a key for; a debug tileset needs none.
    private var keyService: CredentialService? {
        if let override = ProcessInfo.processInfo.environment["ALSOMAPS_TILESET_URL"], !override.isEmpty { return nil }
        return settings.tileSource.ionAssetID == nil ? .googleMaps : .cesiumIon
    }

    /// The key to stream with, or nil with a message saying how to get one.
    private func requireKey(for service: CredentialService) -> String? {
        keyInUse = CredentialStore.shared.key(for: service)
        statusMessage = keyInUse == nil ? Self.missingKeyMessage(service) : nil
        return keyInUse
    }

    private static func missingKeyMessage(_ service: CredentialService) -> String {
        #if os(tvOS)
        "Set \(service.environmentVariable) in Config/Secrets.xcconfig (or the scheme environment)."
        #else
        if CredentialStore.shared.choice == .app, let problem = CredentialStore.shared.appKeyProblem { return problem }
        return CredentialStore.shared.choice == .app && CredentialStore.shared.canUseAppKeys
            ? "Getting the app's \(service.name) key…"
            : "Add a \(service.name) key to load the map."
        #endif
    }

    /// Keys can change at any time: rotated, or edited by the user. Restarts
    /// on a new key, and reacts to the service refusing the current one.
    /// `update` calls this, but it needs calling every frame without a
    /// streamer too, so a key arriving starts one.
    func updateKey() {
        guard started, let service = keyService else { return }
        let store = CredentialStore.shared
        if store.key(for: service) != keyInUse {
            restart()
            return
        }
        guard streamer != nil else {
            let message = Self.missingKeyMessage(service)
            if statusMessage != message { statusMessage = message }
            return
        }
        guard let status = streamer?.takeKeyFailureStatus(), status != 0 else { return }
        if store.usesAppKey(for: service) {
            if status == 429 {
                statusMessage = "The app's shared key is busy. Add your own key to keep going."
            } else {
                // It may have been rotated. A new key arrives through the
                // check above.
                Task { await store.refreshAppKeys(force: true) }
            }
        } else if store.usesOwnKey(for: service), renderedTiles.isEmpty {
            statusMessage = status == 429
                ? "Your \(service.name) key has reached its quota."
                : "\(service.name) rejected your key. Check it in Keys."
        }
    }

    // MARK: Frame loop

    /// One selection and load pass; call once per rendered frame.
    func update(deltaTime: Float) {
        updateKey()
        guard let streamer else { return }
        let signposter = Signposts.frame
        let update = signposter.beginInterval("Update", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Update", update) }
        #if DEBUG
        let updateStart = Date()
        defer { debugSlowestUpdate = max(debugSlowestUpdate, Date().timeIntervalSince(updateStart)) }
        #endif
        let frame = streamer.update(withDeltaTime: deltaTime)

        for id in frame.freedTileIDs {
            tileEntities.removeValue(forKey: id.uint64Value)?.removeFromParent()
            tileBoxes.removeValue(forKey: id.uint64Value)
        }

        if customTileHandler != nil {
            frame.tileTransforms.withUnsafeBytes { buffer in
                let placements = buffer.bindMemory(to: simd_float4x4.self)
                drawnTiles = frame.tilesToRender.enumerated().map { ($1, placements[$0]) }
            }
        } else {
            var visible = Set<UInt64>()
            frame.tileTransforms.withUnsafeBytes { buffer in
                let placements = buffer.bindMemory(to: simd_float4x4.self)
                for (index, tile) in frame.tilesToRender.enumerated() {
                    visible.insert(tile.identifier)
                    // Built off the main thread before cesium-native counted the
                    // tile as loaded; here it only needs adding.
                    if tileEntities[tile.identifier] == nil, let entity = tile.renderObject as? Entity {
                        tileEntities[tile.identifier] = entity
                        tilesRoot.addChild(entity)
                    }
                    // Placed relative to the current anchor every frame, so there's
                    // no fixed origin for precision to drift away from.
                    tileEntities[tile.identifier]?.transform = Transform(matrix: placements[index])
                }
            }
            for (id, entity) in tileEntities {
                entity.isEnabled = visible.contains(id)
            }
        }
        renderedTiles = frame.tilesToRender
        if showsTileBounds { updateTileBoxes(frame) }

        let newCredits = frame.credits.map { Credit(text: $0.text, imageURL: $0.imageURL.flatMap(URL.init(string:))) }
        if credits != newCredits { credits = newCredits }
        if frame.loadProgress >= 100, loadProgress < 100 {
            Signposts.tiles.emitEvent("LoadComplete")
            statusMessage = nil
        }
        loadProgress = frame.loadProgress
        let fetch = streamer.fetchStats()
        let newStats = Stats(renderedTiles: frame.tilesToRender.count, entities: tileEntities.count,
                             cacheHits: Int(fetch.cacheHits), revalidated: Int(fetch.revalidated),
                             networkLoads: Int(fetch.networkLoads),
                             networkMegabytes: Double(fetch.networkBytes) / 1_048_576)
        if stats != newStats { stats = newStats }

        #if DEBUG
        debugLogElapsed += deltaTime
        if Self.logsStats, debugLogElapsed > 1 {
            debugLogElapsed = 0
            print("[AlsoMaps] render \(frame.tilesToRender.count) tiles, \(tileEntities.count) entities, progress \(Int(frame.loadProgress))%, anchor \(String(format: "%.4f, %.4f", inputs.anchor.coordinate.latitude, inputs.anchor.coordinate.longitude)), height \(Int(inputs.anchor.height)) m, slowest update \(String(format: "%.1f", debugSlowestUpdate * 1000)) ms, fetch \(fetch.cacheHits) cached / \(fetch.revalidated) revalidated / \(fetch.networkLoads) downloaded (\(String(format: "%.1f", Double(fetch.networkBytes) / 1_048_576)) MB)")
            debugSlowestUpdate = 0
        }
        #endif
    }

    /// Samples the most detailed surface across 0.8 × `radius` metres around
    /// `centre` and reports the lowest hit, metres above the ellipsoid (NaN
    /// if none), on the main thread during a later update. May load tiles.
    func sampleGroundHeight(around centre: GeoCoordinate, radius: Double,
                            _ completion: @escaping @Sendable (Double) -> Void) {
        streamer?.sampleGroundHeight(latitude: centre.latitude, longitude: centre.longitude,
                                     radius: radius, completion: completion)
    }

    /// The extent and height range of each tile drawn last frame: ground
    /// estimates from what's loaded, with no network.
    func renderedHeightRanges() -> [TileHeightRange] {
        renderedTiles.map {
            TileHeightRange(centre: $0.centerECEF, radius: $0.radius,
                            minimumHeight: $0.minimumHeight, maximumHeight: $0.maximumHeight)
        }
    }

    // MARK: Tile bounds

    /// Each box is built once, in its tile's own frame, so it moves with the
    /// tile; only its colour changes as the tile enters or leaves the view.
    private func updateTileBoxes(_ frame: CNFrame) {
        guard let data = frame.tileBounds else { return }
        data.withUnsafeBytes { buffer in
            let bounds = buffer.bindMemory(to: CNTileBounds.self)
            for (index, tile) in frame.tilesToRender.enumerated() where index < bounds.count {
                let box = bounds[index]
                let material = box.inView ? insideViewMaterial : outsideViewMaterial
                if let existing = tileBoxes[tile.identifier] {
                    if existing.inView != box.inView {
                        existing.entity.model?.materials = [material]
                        tileBoxes[tile.identifier]?.inView = box.inView
                    }
                } else if let parent = tileEntities[tile.identifier], let mesh = DebugLines.box(box) {
                    let entity = ModelEntity(mesh: mesh, materials: [material])
                    parent.addChild(entity)
                    tileBoxes[tile.identifier] = (entity, box.inView)
                }
            }
        }
    }

    private func removeTileBoxes() {
        for box in tileBoxes.values { box.entity.removeFromParent() }
        tileBoxes = [:]
    }

    // MARK: Applying

    private func applyInputs() {
        guard let streamer else { return }
        streamer.anchorLatitude = inputs.anchor.coordinate.latitude
        streamer.anchorLongitude = inputs.anchor.coordinate.longitude
        streamer.anchorHeight = inputs.anchor.height
        streamer.streamingRadius = inputs.streamingRadius
        streamer.regionHeading = inputs.regionHeading
        streamer.viewPosition = inputs.lod.position
        streamer.viewDirection = inputs.lod.direction
        streamer.viewUp = inputs.lod.up
        streamer.viewFieldOfView = inputs.lod.fieldOfView
        streamer.viewAspect = inputs.lod.aspect
    }

    private func applySettings() {
        guard let streamer else { return }
        streamer.maximumScreenSpaceError = settings.detail
        streamer.culledScreenSpaceError = settings.outerDetail
        streamer.maximumSimultaneousTileLoads = Int(settings.simultaneousLoads)
        streamer.maximumCachedBytes = Int64(settings.cacheMegabytes * 1024 * 1024)
        streamer.forbidHoles = settings.forbidHoles
        streamer.reportsTileBounds = showsTileBounds
        tileUploader.setConcurrency(Int(settings.uploadConcurrency))
    }

    /// A secret from the scheme environment or, via Info.plist, from
    /// Config/Secrets.xcconfig; nil if unset or still a placeholder.
}
