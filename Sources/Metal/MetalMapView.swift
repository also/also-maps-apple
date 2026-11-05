// The map window on macOS and iOS; visionOS draws its immersive mode with
// MetalImmersiveContent instead.
#if !os(visionOS)
import MetalKit
import SwiftUI

/// ScreenMapView, drawn by MetalTileRenderer instead of RealityKit while
/// Settings › General › Draw with Metal is on. Switching rebuilds the tiles
/// for the other renderer (TileStreaming restarts; they reload from the
/// cache).
struct MetalOptionMapView: View {
    let map: ScreenMap
    var creditLineLimit: Int? = 1
    @AppStorage(ViewPreferences.drawsWithMetalKey) private var drawsWithMetalSetting = false

    private var metal: MetalTileRenderer? {
        // Read through the setting's storage so a change redraws this view.
        _ = drawsWithMetalSetting
        return ViewPreferences.drawsWithMetal ? MetalTileRenderer.shared : nil
    }

    var body: some View {
        let metal = metal
        ScreenMapView(map: map, creditLineLimit: creditLineLimit,
                      sceneOverride: metal.map { AnyView(MetalMapView(map: map, renderer: $0)) })
            .onChange(of: metal != nil, initial: true) { _, drawsWithMetal in
                map.streaming.customTileHandler = drawsWithMetal ? metal?.handler : nil
            }
    }
}

/// The map drawn with MetalTileRenderer from the window camera. The
/// RealityKit view underneath still drives the frame loop; it just has
/// nothing to draw.
struct MetalMapView {
    let map: ScreenMap
    let renderer: MetalTileRenderer

    func makeCoordinator() -> Coordinator { Coordinator(map: map, renderer: renderer) }

    private func makeView(_ coordinator: Coordinator) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearDepth = 0
        view.clearColor = MetalTileRenderer.skyColour
        view.preferredFramesPerSecond = 60
        view.delegate = coordinator
        return view
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let map: ScreenMap
        private let renderer: MetalTileRenderer
        private let queue: MTLCommandQueue?
        private var drawLog = MetalDrawLog()

        init(map: ScreenMap, renderer: MetalTileRenderer) {
            self.map = map
            self.renderer = renderer
            queue = renderer.device.makeCommandQueue()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                guard view.drawableSize.height > 0,
                      let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                      let commands = queue?.makeCommandBuffer()
                else { return }
                let tiles = map.streaming.drawnTiles
                let root = map.streaming.tilesRoot.transform.matrix
                // The clay and sun study, when any of it is on: its shadow
                // pass goes in first, before the pass that reads it.
                let inputs = map.streaming.inputs
                let lighting = SunStudy.shared.lighting(anchor: inputs.anchor, streamingRadius: inputs.streamingRadius)
                    .map { renderer.prepare($0, commands: commands, tiles: tiles) }
                pass.colorAttachments[0].clearColor = lighting?.clearColour ?? MetalTileRenderer.skyColour
                guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
                let aspect = Float(view.drawableSize.width / view.drawableSize.height)
                let halfHeight = Float(tan(ScreenMap.fieldOfView / 2))
                let (near, far) = map.clipping
                let projection = MetalProjection.perspective(
                    tangents: [halfHeight * aspect, halfHeight * aspect, halfHeight, halfHeight],
                    near: Float(near), far: Float(far))
                let camera = map.cameraMatrix
                let viewProjection = projection * camera.inverse
                let statistics = renderer.encode(encoder, colour: view.colorPixelFormat, depth: view.depthStencilPixelFormat,
                                viewProjection: viewProjection, root: root, tiles: tiles,
                                lighting: lighting,
                                eye: SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z))
                if let lighting {
                    renderer.encodeSunPath(encoder, colour: view.colorPixelFormat, depth: view.depthStencilPixelFormat,
                                           viewProjection: viewProjection, root: root, lighting: lighting,
                                           aspect: aspect)
                }
                encoder.endEncoding()
                commands.present(drawable)
                commands.commit()
                drawLog.record(statistics)
            }
        }
    }
}

#if os(macOS)
extension MetalMapView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { makeView(context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) {}
}
#else
extension MetalMapView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = makeView(context.coordinator)
        // Touches go to TouchSurface over the map.
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {}
}
#endif
#endif
