import RealityKit
import SwiftUI

@MainActor
@Observable
final class StaticMap {
    let view: StaticView
    let streaming: TileStreaming
    private(set) var framesPerSecond = 0
    /// Seconds from the first frame to the first drawn tile, and to every
    /// requested tile being drawn: how fast the view fills in.
    private(set) var secondsToFirstTile: Float?
    private(set) var secondsToComplete: Float?
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var elapsed: Float = 0
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var frameElapsed: Float = 0

    init(view: StaticView) {
        self.view = view
        streaming = TileStreaming(inputs: view.inputs, settings: view.settings)
    }

    func attach(_ content: inout RealityViewCameraContent) {
        content.camera = .virtual
        // Tiles come placed in the anchor's level frame (x east, y up, z
        // south, metres), so the scene is that frame, unscaled.
        content.add(streaming.tilesRoot)
        content.add(makeCamera())

        streaming.start()
        if view.samplesGround {
            streaming.sampleGroundHeight(around: view.inputs.anchor.coordinate,
                                         radius: view.inputs.streamingRadius) { [weak self] height in
                MainActor.assumeIsolated {
                    guard let self, height.isFinite else { return }
                    self.streaming.inputs.anchor.height = min(max(height, -500), 9_000)
                }
            }
        }
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.update(deltaTime: Float(event.deltaTime))
            }
        }
    }

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var inputs = streaming.inputs
        inputs.lod.aspect = size.width / size.height
        streaming.inputs = inputs
    }

    private func update(deltaTime: Float) {
        streaming.update(deltaTime: deltaTime)
        elapsed += deltaTime
        if secondsToFirstTile == nil, streaming.stats.renderedTiles > 0 {
            secondsToFirstTile = elapsed
        }
        if secondsToComplete == nil, streaming.stats.renderedTiles > 0, streaming.loadProgress >= 100 {
            secondsToComplete = elapsed
            #if DEBUG
            print("[AlsoMaps] \(view.name): first tile \(String(format: "%.1f", secondsToFirstTile ?? 0)) s, loaded \(String(format: "%.1f", elapsed)) s, \(streaming.stats.renderedTiles) tiles, \(String(format: "%.1f", streaming.stats.networkMegabytes)) MB downloaded")
            #endif
        }
        frameCount += 1
        frameElapsed += deltaTime
        if frameElapsed >= 1 {
            framesPerSecond = Int((Float(frameCount) / frameElapsed).rounded())
            #if DEBUG
            print("[AlsoMaps] \(framesPerSecond) fps")
            #endif
            frameCount = 0
            frameElapsed = 0
        }
    }

    /// A RealityKit camera at the LOD camera, with its vertical field of view.
    private func makeCamera() -> Entity {
        let lod = view.inputs.lod
        let forward = SIMD3<Float>(lod.direction), up = SIMD3<Float>(lod.up)
        let right = simd_cross(forward, up)

        let camera = Entity()
        camera.components.set(PerspectiveCameraComponent(near: view.near, far: view.far,
                                                         fieldOfViewInDegrees: Float(lod.fieldOfView * 180 / .pi)))
        // A camera looks down its −z.
        camera.orientation = simd_quatf(simd_float3x3(right, up, -forward))
        camera.position = SIMD3<Float>(lod.position)
        return camera
    }
}

struct StaticMapView: View {
    private let view: StaticView
    private let showsDiagnostics: Bool
    private let creditLineLimit: Int?
    @State private var map: StaticMap?
    @State private var viewportSize: CGSize = .zero

    init(view: StaticView, showsDiagnostics: Bool = true, creditLineLimit: Int? = 1) {
        self.view = view
        self.showsDiagnostics = showsDiagnostics
        self.creditLineLimit = creditLineLimit
    }

    private static func format(_ seconds: Float?) -> String {
        seconds.map { String(format: "%.1f s", $0) } ?? "…"
    }

    var body: some View {
        RealityView { content in
            // Construct the model when the scene is made, once per view identity.
            // Parent updates (such as opening Places) only rebuild this view value.
            let map = self.map ?? StaticMap(view: view)
            self.map = map
            map.resize(to: viewportSize)
            map.attach(&content)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            viewportSize = $0
            map?.resize(to: $0)
        }
        .background(Color(red: 0.55, green: 0.7, blue: 0.85))
        .overlay(alignment: .topLeading) {
            if let map, showsDiagnostics {
                Text("\(map.streaming.stats.renderedTiles) tiles · \(Int(map.streaming.loadProgress))% · \(map.framesPerSecond) fps · cache \(map.streaming.stats.cacheHits)/\(map.streaming.stats.revalidated)/\(map.streaming.stats.networkLoads) · first \(Self.format(map.secondsToFirstTile)) · done \(Self.format(map.secondsToComplete))")
                    .font(.caption.monospacedDigit())
                    .padding(6)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
        .overlay(alignment: .bottom) {
            if let map {
                AttributionBar(streaming: map.streaming, creditLineLimit: creditLineLimit)
                    .padding(8)
            }
        }
    }
}

/// Google's terms require the Google Maps logo and the data attribution for
/// the tiles on screen to be visible alongside them. The logo is Google's
/// white variant, so it sits on a dark backing.
struct AttributionBar: View {
    let streaming: TileStreaming
    /// A guest place's streamer, whose credits show too.
    var guest: TileStreaming?
    var creditLineLimit: Int? = 1

    private var credits: [TileStreaming.Credit] {
        guard let guest else { return streaming.credits }
        // Each once, the map's first.
        var seen = Set<TileStreaming.Credit>()
        return (streaming.credits + guest.credits).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(spacing: 4) {
            if let message = streaming.statusMessage {
                Text(message).font(.callout)
            }
            HStack(spacing: 8) {
                if streaming.showsGoogleLogo {
                    Image("GoogleMapsLogo")
                        .accessibilityLabel("Google Maps")
                }
                Text(credits.map(\.text).filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(creditLineLimit)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: .capsule)
    }
}
