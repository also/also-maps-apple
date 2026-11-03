import ARKit
import CompositorServices
import Metal
import SwiftUI

/// The immersive presentation drawn with Metal (a spike; Settings › Immersion):
/// the same MapModel, placement and streaming as ImmersiveMapView, but the
/// tiles are drawn by MetalTileRenderer into a CompositorLayer, with their
/// real depth. The volume stays the control panel; look-and-pinch on the map
/// isn't available, but controllers are.
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

/// One texture per eye if the device offers it, else both in one, and no
/// foveation: MetalTileRenderer draws each view with one projection.
struct MetalImmersiveConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : .shared
        configuration.isFoveationEnabled = false
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

            frame.startUpdate()
            model.metalImmersiveTick(deltaTime: min(max(deltaTime, 0), 0.1))
            frame.endUpdate()

            try? await clock.sleep(until: timing.optimalInputTime, tolerance: nil)

            frame.startSubmission()
            if let drawable = frame.queryDrawable() {
                render(drawable, at: presentation)
            }
            frame.endSubmission()
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
        // Measured once, as ImmersiveMapView does: the eye the map is placed
        // around. Implausible heights (tracking glitches) keep the assumed eye.
        if !measuredEye, anchor != nil {
            measuredEye = true
            let head = originFromDevice.columns.3
            if (0.5...2.5).contains(head.y) { model.measuredEye = SIMD3<Double>(SIMD3(head.x, head.y, head.z)) }
        }

        guard let commands = queue?.makeCommandBuffer() else { return }
        let root = model.tilesInImmersiveSpace
        let tiles = model.streaming.drawnTiles
        // Views sharing a texture (the shared layout) are drawn in one pass,
        // cleared once, each in its own viewport.
        let byTexture = Dictionary(grouping: drawable.views.indices) { drawable.views[$0].textureMap.textureIndex }
        for (textureIndex, viewIndices) in byTexture.sorted(by: { $0.key < $1.key }) {
            let colour = drawable.colorTextures[textureIndex], depth = drawable.depthTextures[textureIndex]
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = colour
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MetalTileRenderer.skyColour
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0
            pass.depthAttachment.storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
            for index in viewIndices {
                let view = drawable.views[index]
                encoder.setViewport(view.textureMap.viewport)
                // The compositor's projection: reverse Z over its default
                // depth range, which the cleared 0 is the far end of.
                metal.encode(encoder, colour: colour.pixelFormat, depth: depth.pixelFormat,
                             viewProjection: drawable.computeProjection(viewIndex: index)
                                 * (originFromDevice * view.transform).inverse,
                             root: root, tiles: tiles)
            }
            encoder.endEncoding()
        }
        drawable.encodePresent(commandBuffer: commands)
        commands.commit()
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
