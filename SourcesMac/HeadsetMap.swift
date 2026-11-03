import ARKit
import CompositorServices
import Metal
import RealityKit
import SwiftUI

/// The window's map shown on a Vision Pro (macOS spatial rendering): the Mac
/// renders each eye and streams the frames to the headset. A spike.
///
/// RemoteImmersiveSpace only takes Metal (a CompositorLayer), so the map's
/// RealityKit scene is drawn through a RealityRenderer, once per eye, into
/// the compositor's textures. The world is placed as in the visionOS
/// immersive space (EyeLevelModel): the camera on your eye, level with the
/// floor, scaled so the ground beneath it is on the floor; or 1:1 at human
/// scale. The window keeps its controls but shows nothing while the headset
/// has the map.
@MainActor
@Observable
final class HeadsetSession {
    static let spaceID = "headset"

    /// The map the next space renders, set by the window that opens it.
    var map: ScreenMap?
    private(set) var isOpen = false

    func didOpen() { isOpen = true }

    func didClose() {
        isOpen = false
        map?.leaveHeadset()
    }
}

/// The space's content: a compositor layer drawn by `HeadsetRenderer`. It
/// reads the headset's identifier here, since only the space's own
/// environment has it (the app's is nil).
struct HeadsetContent: CompositorContent {
    let session: HeadsetSession
    @Environment(\.remoteDeviceIdentifier) private var remoteDevice

    var body: some CompositorContent {
        CompositorLayer(configuration: HeadsetLayerConfiguration()) { layerRenderer in
            guard let remoteDevice else {
                print("Headset: no remote device; can't track the head, so nothing would be presented")
                return
            }
            guard let map = session.map else {
                print("Headset: no map to show")
                return
            }
            do {
                let renderer = try HeadsetRenderer(map: map, layerRenderer: layerRenderer, device: remoteDevice)
                session.didOpen()
                Task { @MainActor in
                    await renderer.run()
                    session.didClose()
                }
            } catch {
                print("Headset: couldn't start: \(error)")
            }
        }
    }
}

/// Dedicated textures per eye, without foveation: RealityRenderer draws a
/// whole texture with one projection.
struct HeadsetLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = false
        // Usage stays at the defaults (render target plus shader read): an
        // unsupported usage is a fatal error when the space opens.
        if capabilities.supportedColorFormats(options: []).contains(.bgra8Unorm_srgb) {
            configuration.colorFormat = .bgra8Unorm_srgb
        }
        if capabilities.supportedDepthFormats.contains(.depth32Float) {
            configuration.depthFormat = .depth32Float
        }
    }
}

/// Runs the frame loop on the main actor, since the map and RealityRenderer
/// both live there.
@MainActor
final class HeadsetRenderer {
    private let map: ScreenMap
    private let layerRenderer: LayerRenderer
    private let session: ARKitSession
    private let worldTracking = WorldTrackingProvider()
    private let renderer: RealityRenderer
    private let eye = Entity()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// Signalled when the last eye is drawn; the present waits on it.
    private let rendered: MTLSharedEvent
    private var frameIndex: UInt64 = 0
    /// ALSOMAPS_METAL=1: draws the tiles itself instead of RealityRenderer,
    /// if it shares the compositor's GPU.
    private let metal: MetalTileRenderer?
    /// Whether the eye has been measured, on the first tracked frame.
    private var measuredEye = false

    /// The visionOS immersive host's geometry (MapPresentation.immersive):
    /// the ground on the floor, raised slightly, the map's centre 5.6 m
    /// ahead, a shown square 10 m across. The eye is assumed until measured.
    static func room(eye: SIMD3<Double> = [0, 1.6, 0]) -> RoomGeometry {
        RoomGeometry(designEye: eye,
                     placementLevel: [eye.x, 0.02, eye.z - 5.6],
                     placementDown: [eye.x, eye.y - 0.3, eye.z - 5.6],
                     contentHalfWidth: 5)
    }
    /// ALSOMAPS_HEADSET_TEST=1 fills each eye with a colour instead of the
    /// map, to tell "frames don't reach the headset" from "RealityRenderer
    /// draws nothing".
    private static let fillsTestColour = ProcessInfo.processInfo.environment["ALSOMAPS_HEADSET_TEST"] == "1"
    /// Counts for the once-a-second log line.
    private var loggedDrawable = false
    private var log = (frames: 0, drawables: 0, anchored: 0, failures: 0, lastPrint: Date())

    init(map: ScreenMap, layerRenderer: LayerRenderer, device remote: RemoteDeviceIdentifier) throws {
        self.map = map
        self.layerRenderer = layerRenderer
        session = ARKitSession(device: remote)
        renderer = try RealityRenderer()
        device = layerRenderer.device
        if let shared = MetalTileRenderer.shared {
            if shared.device === layerRenderer.device {
                metal = shared
            } else {
                print("Headset: the Metal renderer is on another GPU than the compositor; using RealityRenderer")
                metal = nil
            }
        } else {
            metal = nil
        }
        guard let queue = device.makeCommandQueue(), let event = device.makeSharedEvent() else {
            throw HeadsetError.metal
        }
        self.queue = queue
        rendered = event
        // The window's sky (ScreenMapView).
        renderer.cameraSettings.colorBackground = .color(CGColor(red: 0.55, green: 0.7, blue: 0.85, alpha: 1))
        renderer.entities.append(contentsOf: [map.enterHeadset(), eye])
        map.headsetRoom = Self.room()
        renderer.activeCamera = eye
    }

    enum HeadsetError: Error { case metal }

    func run() async {
        do {
            try await session.run([worldTracking])
        } catch {
            print("Headset: world tracking didn't start (\(error)); the view won't follow the head")
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
            map.headsetTick(deltaTime: min(max(deltaTime, 0), 0.1))
            frame.endUpdate()

            try? await clock.sleep(until: timing.optimalInputTime, tolerance: nil)

            frame.startSubmission()
            for drawable in frame.queryDrawables() {
                render(drawable, deltaTime: deltaTime, at: presentation)
            }
            frame.endSubmission()
            printLog()
        }
    }

    private func render(_ drawable: LayerRenderer.Drawable, deltaTime: Float, at presentation: LayerRenderer.Clock.Instant) {
        let time = Self.seconds(LayerRenderer.Clock.Instant.epoch.duration(to: presentation))
        let anchor = worldTracking.state == .running ? worldTracking.queryDeviceAnchor(atTimestamp: time) : nil
        drawable.deviceAnchor = anchor
        log.drawables += 1
        if !loggedDrawable {
            loggedDrawable = true
            func describe(_ texture: MTLTexture) -> String {
                "\(texture.width)×\(texture.height) \(texture.pixelFormat.rawValue) type \(texture.textureType.rawValue) "
                    + "slices \(texture.arrayLength) usage \(texture.usage.rawValue)"
            }
            print("Headset: \(drawable.views.count) views; colour \(drawable.colorTextures.map(describe)); "
                  + "depth \(drawable.depthTextures.map(describe)); default depth range \(drawable.depthRange); "
                  + "head \(anchor.map { $0.originFromAnchorTransform.columns.3 } ?? .zero)")
        }
        if anchor != nil { log.anchored += 1 }
        let originFromDevice = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        // Measured once, as on visionOS: the eye the map is placed around.
        // Implausible heights (tracking glitches) keep the assumed eye.
        if !measuredEye, anchor != nil {
            measuredEye = true
            let head = SIMD3<Double>(SIMD3(originFromDevice.columns.3.x, originFromDevice.columns.3.y,
                                           originFromDevice.columns.3.z))
            if (0.5...2.5).contains(head.y) { map.headsetRoom = Self.room(eye: head) }
        }

        let (near, far) = map.clipping
        drawable.depthRange = SIMD2(Float(far), Float(near))
        frameIndex += 1
        if Self.fillsTestColour {
            present(drawable, clearingColour: true)
            return
        }
        if let metal {
            renderMetal(drawable, with: metal, originFromDevice: originFromDevice)
            return
        }
        for (index, view) in drawable.views.enumerated() {
            // The scene is the room: the map is placed in it directly.
            eye.transform = Transform(matrix: originFromDevice * view.transform)
            eye.components.set(ProjectiveTransformCameraComponent(
                projectionMatrix: Self.projection(tangents: Self.tangents(drawable.computeProjection(viewIndex: index)),
                                                  near: Float(near), far: Float(far))))
            let isLast = index == drawable.views.count - 1
            do {
                let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: drawable.colorTextures[index]))
                try renderer.updateAndRender(deltaTime: index == 0 ? TimeInterval(deltaTime) : 0, cameraOutput: output,
                                             actionsAfterRender: isLast ? [.signal(rendered, value: frameIndex)] : [])
            } catch {
                if log.failures == 0 { print("Headset: render failed: \(error)") }
                log.failures += 1
                if isLast { rendered.signaledValue = frameIndex }
            }
        }

        present(drawable, clearingColour: false)
    }

    /// ALSOMAPS_METAL=1: both eyes in one command buffer, with the map's
    /// real depth in the compositor's depth textures, through the
    /// compositor's own projection (reverse Z, from the depth range set).
    private func renderMetal(_ drawable: LayerRenderer.Drawable, with metal: MetalTileRenderer,
                             originFromDevice: simd_float4x4) {
        guard let commands = queue.makeCommandBuffer() else { return }
        let root = map.streaming.tilesRoot.transform.matrix
        let tiles = map.streaming.drawnTiles
        for (index, view) in drawable.views.enumerated() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.colorTextures[index]
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MetalTileRenderer.skyColour
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = drawable.depthTextures[index]
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0
            pass.depthAttachment.storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
            // The scene is the room: the map is placed in it directly.
            let viewMatrix = (originFromDevice * view.transform).inverse
            metal.encode(encoder, colour: drawable.colorTextures[index].pixelFormat,
                         depth: drawable.depthTextures[index].pixelFormat,
                         viewProjection: drawable.computeProjection(viewIndex: index) * viewMatrix,
                         root: root, tiles: tiles)
            encoder.endEncoding()
        }
        commands.encodeSignalEvent(rendered, value: frameIndex)
        drawable.encodePresent(commandBuffer: commands)
        commands.commit()
    }

    private func present(_ drawable: LayerRenderer.Drawable, clearingColour: Bool) {
        guard let commands = queue.makeCommandBuffer() else { return }
        if clearingColour {
            for colour in drawable.colorTextures {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = colour
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
                pass.colorAttachments[0].storeAction = .store
                commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
        } else {
            commands.encodeWaitForEvent(rendered, value: frameIndex)
        }
        // Nothing writes depth; clear it to a kilometre away (reverse Z).
        // Not the far plane itself: the compositor clips what isn't between
        // the planes.
        let range = drawable.depthRange
        let (far, near) = (range.x, range.y)
        let distance = min(1_000, far * 0.9)
        let clearDepth = Double(near * (far - distance) / (distance * (far - near)))
        for depth in drawable.depthTextures {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = clearDepth
            pass.depthAttachment.storeAction = .store
            commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        drawable.encodePresent(commandBuffer: commands)
        commands.commit()
    }

    /// An off-axis perspective from the view's tangents (left, right, top,
    /// bottom), looking down −z, reverse Z (depth 1 at near, 0 at far):
    /// RealityRenderer draws nothing with a forward-Z projection.
    static func projection(tangents: SIMD4<Float>, near: Float, far: Float) -> simd_float4x4 {
        let left = -tangents[0], right = tangents[1], top = tangents[2], bottom = -tangents[3]
        let width = right - left, height = top - bottom
        return simd_float4x4(columns: (
            [2 / width, 0, 0, 0],
            [0, 2 / height, 0, 0],
            [(right + left) / width, (top + bottom) / height, near / (far - near), -1],
            [0, 0, near * far / (far - near), 0]
        ))
    }

    /// The tangents (left, right, top, bottom) of a perspective projection
    /// looking down −z, whatever its depth mapping: `view.tangents` isn't
    /// available on macOS.
    static func tangents(_ projection: simd_float4x4) -> SIMD4<Float> {
        let width = 2 / projection.columns.0.x, height = 2 / projection.columns.1.y
        let centreX = projection.columns.2.x * width / 2, centreY = projection.columns.2.y * height / 2
        return [width / 2 - centreX, width / 2 + centreX, height / 2 + centreY, height / 2 - centreY]
    }

    private func printLog() {
        log.frames += 1
        guard Date().timeIntervalSince(log.lastPrint) >= 1 else { return }
        print("Headset: \(log.frames) frames, \(log.drawables) drawables, \(log.anchored) with a device anchor, "
              + "\(log.failures) render failures, tracking \(worldTracking.state), "
              + "GPU finished \(rendered.signaledValue) of \(frameIndex) drawables")
        log = (0, 0, 0, 0, Date())
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}
