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
            super.init()
            map.onTap = { [weak self] point in self?.pick(at: point) }
        }

        /// Logs the map point under a click or tap. The scene frame is the
        /// map frame, so the georeference takes a hit back to ECEF. (The
        /// RealityKit debug lines aren't drawn in this view.)
        private func pick(at point: SIMD2<Double>) {
            MainActor.assumeIsolated { pick(main: point) }
        }

        private func pick(main point: SIMD2<Double>) {
            guard let ray = MetalPicking.ray(throughPoint: point, viewSize: map.viewportSize,
                                             halfHeightTangent: tan(ScreenMap.fieldOfView / 2),
                                             sceneFromCamera: map.cameraMatrix) else { return }
            guard let hit = renderer.pick(ray: ray, tiles: map.streaming.drawnTiles,
                                          root: map.streaming.tilesRoot.transform.matrix) else {
                print("[AlsoMaps] Pick at \(point): no hit")
                return
            }
            let georeference = ScreenView.georeference(camera: map.navigation.camera)
            let (coordinate, height) = Geodesy.geodetic(georeference.ecef(map: SIMD3<Double>(hit.position)))
            print(String(format: "[AlsoMaps] Pick at (%.0f, %.0f): %.5f, %.5f, %.1f m, %.1f m from the eye",
                         point.x, point.y, coordinate.latitude, coordinate.longitude, height, hit.distance))
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                guard view.drawableSize.height > 0,
                      let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                      let commands = queue?.makeCommandBuffer(),
                      let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
                else { return }
                let aspect = Float(view.drawableSize.width / view.drawableSize.height)
                let halfHeight = Float(tan(ScreenMap.fieldOfView / 2))
                let (near, far) = map.clipping
                let projection = MetalProjection.perspective(
                    tangents: [halfHeight * aspect, halfHeight * aspect, halfHeight, halfHeight],
                    near: Float(near), far: Float(far))
                let statistics = renderer.encode(encoder, colour: view.colorPixelFormat, depth: view.depthStencilPixelFormat,
                                viewProjection: projection * map.cameraMatrix.inverse,
                                root: map.streaming.tilesRoot.transform.matrix,
                                tiles: map.streaming.drawnTiles)
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
