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
    /// The name of the traces draped over the map; nil if there are none.
    private(set) var tracesName = UserDefaults.standard.string(forKey: TileStreaming.tracesNameKey)
    private(set) var isLoadingTraces = false
    /// Why the last traces couldn't be shown, until it's been read.
    var tracesError: String?

    private var streamer: CNTileStreamer?
    private let tileUploader = TileUploader()
    private let drape = TraceDrape()
    /// sRGB, the teal the traces are drawn in on the web.
    private static let traceColor = SIMD4<Float>(0, 0.863, 0.761, 1)
    private static let tracesNameKey = "tracesName"
    private static let tracesFile = URL.applicationSupportDirectory.appending(path: "traces.geojson")
    private var startedLoading = Date()
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
    private var debugLogElapsed: Float = 0
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
        // Debug: ALSOMAPS_TRACES=<path to GeoJSON> opens it as if picked.
        if let traces = ProcessInfo.processInfo.environment["ALSOMAPS_TRACES"], !traces.isEmpty {
            Task { _ = await openTraces(URL(fileURLWithPath: traces)) }
        }
    }

    // MARK: Traces

    /// Prepares a GeoJSON file and drapes it over the map, keeping a copy so
    /// it's there next launch. Returns a view of it, or nil with `tracesError`
    /// set.
    func openTraces(_ url: URL) async -> Place? {
        isLoadingTraces = true
        defer { isLoadingTraces = false }
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let place = try await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let file = try TraceFile(geoJSON: Data(contentsOf: url, options: .mappedIfSafe), name: name)
                try FileManager.default.createDirectory(at: Self.tracesFile.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try file.data.write(to: Self.tracesFile, options: .atomic)
                return file.place
            }.value
            tracesName = name
            UserDefaults.standard.set(name, forKey: Self.tracesNameKey)
            showTraces()
            return place
        } catch {
            tracesError = error.localizedDescription
            return nil
        }
    }

    func removeTraces() {
        streamer?.removeGeoJSONOverlay()
        tracesName = nil
        UserDefaults.standard.removeObject(forKey: Self.tracesNameKey)
        try? FileManager.default.removeItem(at: Self.tracesFile)
    }

    private func showTraces() {
        streamer?.showGeoJSONOverlay(path: Self.tracesFile.path, lineWidth: 2, color: Self.traceColor) { [weak self] error in
            guard let self, let error else { return }
            self.tracesError = error
            self.removeTraces()
        }
    }

    private func startStreamer() {
        let env = ProcessInfo.processInfo.environment
        let streamer: CNTileStreamer
        showsGoogleLogo = false
        // Debug: ALSOMAPS_TILESET_URL streams any 3D Tiles tileset, no key.
        if let override = env["ALSOMAPS_TILESET_URL"], !override.isEmpty {
            streamer = CNTileStreamer(tilesetURL: override)
        } else if let assetID = settings.tileSource.ionAssetID {
            guard let token = Self.secret(environment: "CESIUM_ION_TOKEN", infoKey: "CesiumIonToken") else {
                statusMessage = "Set CESIUM_ION_TOKEN in Config/Secrets.xcconfig (or the scheme environment)."
                return
            }
            streamer = CNTileStreamer(ionAssetID: assetID, accessToken: token,
                                      smoothNormals: settings.tileSource.smoothNormals)
        } else {
            guard let key = Self.secret(environment: "GOOGLE_MAPS_API_KEY", infoKey: "GoogleMapsAPIKey") else {
                statusMessage = "Set GOOGLE_MAPS_API_KEY in Config/Secrets.xcconfig (or the scheme environment)."
                return
            }
            streamer = CNTileStreamer(tilesetURL: "https://tile.googleapis.com/v1/3dtiles/root.json?key=\(key)")
            showsGoogleLogo = true
        }
        statusMessage = nil
        tileUploader.untexturedColor = settings.tileSource.untexturedColor
        // Before the first update, so every tile goes through it.
        streamer.tileLoadHandler = tileUploader.handler
        streamer.rasterAttachHandler = { [drape] tile, raster, translation, scale in
            drape.attach(tile, raster: raster, translation: translation, scale: scale)
        }
        streamer.rasterDetachHandler = { [drape] tile in drape.detach(tile) }
        self.streamer = streamer
        if tracesName != nil { showTraces() }
        startedLoading = Date()
        applySettings()
        applyInputs()
    }

    /// Drops everything loaded from the old source and streams the new one
    /// at the same view.
    private func restart() {
        guard started else { return }
        for entity in tileEntities.values { entity.removeFromParent() }
        tileEntities = [:]
        tileBoxes = [:]
        renderedTiles = []
        credits = []
        loadProgress = 0
        stats = Stats()
        streamer = nil
        startStreamer()
    }

    // MARK: Frame loop

    /// One selection and load pass; call once per rendered frame.
    func update(deltaTime: Float) {
        guard let streamer else { return }
        let signposter = Signposts.frame
        let update = signposter.beginInterval("Update", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Update", update) }
        #if DEBUG
        let updateStart = Date()
        defer { debugSlowestUpdate = max(debugSlowestUpdate, Date().timeIntervalSince(updateStart)) }
        #endif
        let frame = streamer.update(withDeltaTime: deltaTime)
        drape.finishFrame()

        for id in frame.freedTileIDs {
            tileEntities.removeValue(forKey: id.uint64Value)?.removeFromParent()
            tileBoxes.removeValue(forKey: id.uint64Value)
        }

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
        renderedTiles = frame.tilesToRender
        if showsTileBounds { updateTileBoxes(frame) }

        let newCredits = frame.credits.map { Credit(text: $0.text, imageURL: $0.imageURL.flatMap(URL.init(string:))) }
        if credits != newCredits { credits = newCredits }
        if frame.loadProgress >= 100, loadProgress < 100 {
            Signposts.tiles.emitEvent("LoadComplete")
            #if DEBUG
            print("[AlsoMaps] load complete \(String(format: "%.1f", Date().timeIntervalSince(startedLoading))) s after start, \(frame.tilesToRender.count) tiles")
            #endif
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
        if debugLogElapsed > 1 {
            debugLogElapsed = 0
            print("[AlsoMaps] render \(frame.tilesToRender.count) tiles, \(tileEntities.count) entities, progress \(Int(frame.loadProgress))%, anchor \(String(format: "%.4f, %.4f", inputs.anchor.coordinate.latitude, inputs.anchor.coordinate.longitude)), height \(Int(inputs.anchor.height)) m, slowest update \(String(format: "%.1f", debugSlowestUpdate * 1000)) ms, fetch \(fetch.cacheHits) cached / \(fetch.revalidated) revalidated / \(fetch.networkLoads) downloaded (\(String(format: "%.1f", Double(fetch.networkBytes) / 1_048_576)) MB), rasters \(drape.attachedRasters) attached / \(drape.emptyRasters) empty / \(drape.undrapableTiles) undrapable, \(drape.drapedTiles) draped")
            fflush(stdout)
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
    private static func secret(environment: String, infoKey: String) -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment[environment],
            Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("$(") && !$0.hasPrefix("YOUR_") }
    }
}
