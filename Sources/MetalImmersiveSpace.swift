import ARKit
import CompositorServices
import Metal
import OSLog
import SwiftUI

/// The immersive presentation drawn with Metal (Settings › General › Draw
/// with Metal): the same MapModel, placement and streaming as
/// ImmersiveMapView, but the tiles are drawn by MetalTileRenderer into a
/// CompositorLayer, with their real depth, in mixed or full immersion. The
/// volume stays the control panel; look-and-pinch on the map isn't
/// available, but controllers are.
struct MetalImmersiveContent: CompositorContent {
    static let spaceID = "metal-map"

    let model: MapModel

    var body: some CompositorContent {
        CompositorLayer(configuration: MetalImmersiveConfiguration()) { layerRenderer in
            guard let metal = MetalTileRenderer.shared else { return }
            model.metalImmersiveDidOpen(metal)
            let renderer = MetalImmersiveRenderer(model: model, layerRenderer: layerRenderer, metal: metal)
            Task { @MainActor in
                await renderer.run()
                model.metalImmersiveDidClose()
            }
        }
    }
}

/// Use foveated, dedicated eye textures when supported. Keep the unfoveated
/// dedicated/shared fallback for devices (including simulators) without it.
struct MetalImmersiveConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let wantsFoveation = capabilities.supportsFoveation
            && ProcessInfo.processInfo.environment["ALSOMAPS_METAL_FOVEATION"] != "0"
        let foveatedLayouts = wantsFoveation ? capabilities.supportedLayouts(options: [.foveationEnabled]) : []
        if foveatedLayouts.contains(.dedicated) {
            configuration.layout = .dedicated
            configuration.isFoveationEnabled = true
        } else {
            // This renderer doesn't use texture-array slices yet. Only
            // enable foveation when our dedicated layout is supported.
            let layouts = capabilities.supportedLayouts(options: [])
            configuration.layout = layouts.contains(.dedicated) ? .dedicated : .shared
            configuration.isFoveationEnabled = false
        }
    }
}

/// The frame loop, on the main actor with the model.
@MainActor
final class MetalImmersiveRenderer {
    private let model: MapModel
    private let layerRenderer: LayerRenderer
    private let metal: MetalTileRenderer
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let queue: MTLCommandQueue?
    private var measuredEye = false
    private var drawLog = MetalDrawLog()
    private var log = (frames: 0, anchored: 0, lastPrint: Date())

    init(model: MapModel, layerRenderer: LayerRenderer, metal: MetalTileRenderer) {
        self.model = model
        self.layerRenderer = layerRenderer
        self.metal = metal
        queue = metal.device.makeCommandQueue()
    }

    func run() async {
        do {
            try await session.run([worldTracking])
        } catch {
            print("[AlsoMaps] Metal immersive: world tracking didn't start: \(error)")
        }
        let clock = LayerRenderer.Clock()
        var lastPresentation: LayerRenderer.Clock.Instant?
        while true {
            switch layerRenderer.state {
            case .invalidated:
                session.stop()
                return
            case .paused:
                try? await Task.sleep(for: .milliseconds(100))
                continue
            default:
                break
            }
            guard let frame = layerRenderer.queryNextFrame(), let timing = frame.predictTiming() else {
                await Task.yield()
                continue
            }
            let presentation = timing.presentationTime
            let deltaTime = lastPresentation.map { Float(Self.seconds($0.duration(to: presentation))) } ?? 1 / 90
            lastPresentation = presentation

            // Signposts (docs/profiling.md): where each frame's time goes, and
            // the frames that were late or skipped.
            let signposter = Signposts.frame
            if deltaTime > 1.5 / 90 {
                signposter.emitEvent("FrameGap", "\(deltaTime * 1000, format: .fixed(precision: 1)) ms between presentations")
            }

            frame.startUpdate()
            let tick = signposter.beginInterval("ImmersiveTick", id: signposter.makeSignpostID())
            model.metalImmersiveTick(deltaTime: min(max(deltaTime, 0), 0.1))
            signposter.endInterval("ImmersiveTick", tick)
            frame.endUpdate()

            let wait = signposter.beginInterval("ImmersiveWait", id: signposter.makeSignpostID())
            try? await clock.sleep(until: timing.optimalInputTime, tolerance: nil)
            signposter.endInterval("ImmersiveWait", wait)
            // The wait suspends the main actor, so the space can close in
            // the meantime (exiting Immersive). Submitting to an invalidated
            // layer's frame aborts; the top of the loop handles it instead.
            guard layerRenderer.state == .running else { continue }

            frame.startSubmission()
            // One drawable per target (the display, plus one while capturing,
            // say). None (the layer is going away): drop the frame. Ending a
            // submission without one is invalid and aborts.
            let drawables = frame.queryDrawables()
            guard !drawables.isEmpty else { continue }
            let render = signposter.beginInterval("ImmersiveRender", id: signposter.makeSignpostID())
            for drawable in drawables { self.render(drawable, at: presentation) }
            signposter.endInterval("ImmersiveRender", render)
            frame.endSubmission()
            let overrun = Self.seconds(timing.renderingDeadline.duration(to: clock.now))
            if overrun > 0 {
                signposter.emitEvent("MissedDeadline", "\(overrun * 1000, format: .fixed(precision: 1)) ms after the rendering deadline")
            }
            printLog()
        }
    }

    private func render(_ drawable: LayerRenderer.Drawable, at presentation: LayerRenderer.Clock.Instant) {
        let time = Self.seconds(LayerRenderer.Clock.Instant.epoch.duration(to: presentation))
        let anchor = worldTracking.state == .running ? worldTracking.queryDeviceAnchor(atTimestamp: time) : nil
        drawable.deviceAnchor = anchor
        var originFromDevice = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        #if targetEnvironment(simulator)
        // The simulator's head is on the floor (y = 0); lift it to the
        // assumed eye, or the map's ground is above it.
        originFromDevice.columns.3.y += 1.6
        #endif
        if anchor != nil { log.anchored += 1 }
        // Measured once, like ImmersiveMapView's: the eye the map is placed
        // around. Implausible heights (tracking glitches) keep the assumed eye.
        // A second copy, and it diverges: it takes the first pose without
        // waiting for `isTracked`, as HeadTracker does. A follow-up could share
        // one measurement (notes/metal-renderer.md, "Eye height").
        if !measuredEye, anchor != nil {
            measuredEye = true
            let head = originFromDevice.columns.3
            if (0.5...2.5).contains(head.y) { model.measuredEye = SIMD3<Double>(SIMD3(head.x, head.y, head.z)) }
        }

        guard let commands = queue?.makeCommandBuffer() else { return }
        let root = model.tilesInImmersiveSpace
        let tiles = model.streaming.drawnTiles
        // Mixed immersion (Settings › Immersion): passthrough wherever
        // there's no map. The compositor takes premultiplied colour, so the
        // sky clears to transparent black, and its depth stays at the far
        // plane, where the compositor drops it. Full: an opaque sky that
        // has to be lifted off the far plane to be shown at all.
        let passthrough = !model.fullImmersion
        var statistics = MetalDrawStatistics()
        // Views sharing a texture (the shared layout) are drawn in one pass,
        // cleared once, each in its own viewport.
        let byTexture = Dictionary(grouping: drawable.views.indices) { drawable.views[$0].textureMap.textureIndex }
        for (textureIndex, viewIndices) in byTexture.sorted(by: { $0.key < $1.key }) {
            let colour = drawable.colorTextures[textureIndex], depth = drawable.depthTextures[textureIndex]
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = colour
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = passthrough ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                : MetalTileRenderer.skyColour
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0
            pass.depthAttachment.storeAction = .store
            if layerRenderer.configuration.isFoveationEnabled {
                // Rate maps correspond to the drawable's texture indices.
                // The compositor viewport/projection remain in logical
                // coordinates; Metal maps them to the foveated texture.
                pass.rasterizationRateMap = drawable.rasterizationRateMaps[textureIndex]
            }
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
            for index in viewIndices {
                let view = drawable.views[index]
                encoder.setViewport(view.textureMap.viewport)
                // The compositor's projection: reverse Z over its default
                // depth range, which the cleared 0 is the far end of.
                statistics.add(metal.encode(encoder, colour: colour.pixelFormat, depth: depth.pixelFormat,
                             viewProjection: drawable.computeProjection(viewIndex: index)
                                 * (originFromDevice * view.transform).inverse,
                             root: root, tiles: tiles))
                // Sky left at the far plane would be dropped as clipped,
                // which is what mixed immersion wants.
                if !passthrough {
                    metal.encodeSkyDepth(encoder, colour: colour.pixelFormat, depth: depth.pixelFormat)
                }
            }
            encoder.endEncoding()
        }
        drawable.encodePresent(commandBuffer: commands)
        commands.commit()
        drawLog.record(statistics)
    }

    private func printLog() {
        log.frames += 1
        guard Date().timeIntervalSince(log.lastPrint) >= 1 else { return }
        print("[AlsoMaps] Metal immersive: \(log.frames) frames, \(log.anchored) with a device anchor, "
              + "\(model.streaming.drawnTiles.count) tiles")
        log = (0, 0, Date())
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}
