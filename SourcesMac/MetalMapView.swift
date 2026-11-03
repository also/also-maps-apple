import MetalKit
import SwiftUI

/// The window's map drawn with MetalTileRenderer instead of RealityKit, from
/// the same camera. The RealityKit view underneath still drives the frame
/// loop; it just has nothing to draw.
struct MetalMapView: NSViewRepresentable {
    let map: ScreenMap
    let renderer: MetalTileRenderer

    func makeCoordinator() -> Coordinator { Coordinator(map: map, renderer: renderer) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearDepth = 0
        view.clearColor = MetalTileRenderer.skyColour
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        private let map: ScreenMap
        private let renderer: MetalTileRenderer
        private let queue: MTLCommandQueue?

        init(map: ScreenMap, renderer: MetalTileRenderer) {
            self.map = map
            self.renderer = renderer
            queue = renderer.device.makeCommandQueue()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                // The headset has the map; its renderer draws it.
                guard !map.isInHeadset, view.drawableSize.height > 0,
                      let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                      let commands = queue?.makeCommandBuffer(),
                      let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
                else { return }
                let aspect = Float(view.drawableSize.width / view.drawableSize.height)
                let halfHeight = Float(tan(ScreenMap.fieldOfView / 2))
                let (near, far) = map.clipping
                let projection = MetalTileRenderer.projection(
                    tangents: [halfHeight * aspect, halfHeight * aspect, halfHeight, halfHeight],
                    near: Float(near), far: Float(far))
                renderer.encode(encoder, colour: view.colorPixelFormat, depth: view.depthStencilPixelFormat,
                                viewProjection: projection * map.cameraMatrix.inverse,
                                root: map.streaming.tilesRoot.transform.matrix,
                                tiles: map.streaming.drawnTiles)
                encoder.endEncoding()
                commands.present(drawable)
                commands.commit()
            }
        }
    }
}
