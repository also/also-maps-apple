import RealityKit
import SwiftUI

/// A static view of San Francisco: a fixed RealityKit camera that's also the
/// camera level of detail is selected for. No navigation yet.
@MainActor
@Observable
final class StaticMap {
    /// The Ferry Building.
    static let focus = GeoCoordinate(latitude: 37.7955, longitude: -122.3937)
    /// Over the bay, looking west at downtown, streaming 3 km around.
    static let inputs = StreamingInputs(anchor: StreamingAnchor(coordinate: focus),
                                        lod: .orbit(heading: 3 * .pi / 2,
                                                    elevation: 35 * .pi / 180,
                                                    distance: 2500),
                                        regionHeading: 3 * .pi / 2,
                                        streamingRadius: 3000)

    let streaming = TileStreaming(inputs: inputs, settings: .default)
    private(set) var framesPerSecond = 0
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var frameElapsed: Float = 0

    func attach(_ content: inout RealityViewCameraContent) {
        content.camera = .virtual
        // Tiles come placed in the anchor's level frame (x east, y up, z
        // south, metres), so the scene is that frame, unscaled.
        content.add(streaming.tilesRoot)
        content.add(Self.makeCamera())

        streaming.start()
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.update(deltaTime: Float(event.deltaTime))
            }
        }
    }

    private func update(deltaTime: Float) {
        streaming.update(deltaTime: deltaTime)
        frameCount += 1
        frameElapsed += deltaTime
        if frameElapsed >= 1 {
            framesPerSecond = Int((Float(frameCount) / frameElapsed).rounded())
            #if DEBUG
            print("[MapVolume] \(framesPerSecond) fps")
            #endif
            frameCount = 0
            frameElapsed = 0
        }
    }

    /// A RealityKit camera at the LOD camera, with the same 60° vertical
    /// field of view (the window is square).
    private static func makeCamera() -> Entity {
        let lod = inputs.lod
        let forward = SIMD3<Float>(lod.direction), up = SIMD3<Float>(lod.up)
        let right = simd_cross(forward, up)

        let camera = Entity()
        camera.components.set(PerspectiveCameraComponent(near: 1, far: 100_000,
                                                         fieldOfViewInDegrees: Float(lod.fieldOfView * 180 / .pi)))
        // A camera looks down its −z.
        camera.orientation = simd_quatf(simd_float3x3(right, up, -forward))
        camera.position = SIMD3<Float>(lod.position)
        return camera
    }
}

struct MapWindowView: View {
    @State private var map = StaticMap()

    var body: some View {
        RealityView { content in
            map.attach(&content)
        }
        .frame(width: 900, height: 900)
        .background(Color(red: 0.55, green: 0.7, blue: 0.85))
        .overlay(alignment: .topLeading) {
            Text("\(map.streaming.stats.renderedTiles) tiles · \(Int(map.streaming.loadProgress))% · \(map.framesPerSecond) fps · cache \(map.streaming.stats.cacheHits)/\(map.streaming.stats.revalidated)/\(map.streaming.stats.networkLoads)")
                .font(.caption.monospacedDigit())
                .padding(6)
                .background(.black.opacity(0.5), in: .rect(cornerRadius: 6))
                .foregroundStyle(.white)
                .padding(8)
        }
        .overlay(alignment: .bottom) {
            AttributionBar(streaming: map.streaming)
                .padding(8)
        }
    }
}

/// Google's terms require the Google Maps logo and the data attribution for
/// the tiles on screen to be visible alongside them. The logo is Google's
/// white variant, so it sits on a dark backing.
struct AttributionBar: View {
    let streaming: TileStreaming

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
                Text(streaming.credits.map(\.text).filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: .capsule)
    }
}
