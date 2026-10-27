import RealityKit
import SwiftUI

/// A fixed camera and what to stream for it. The camera is also the camera
/// level of detail is selected for. Pick one with MAPVOLUME_VIEW (`bay`, the
/// default, or `ferry`). Streaming can be overridden for quick experiments:
/// MAPVOLUME_RADIUS (area of interest half-width, metres),
/// MAPVOLUME_DETAIL and MAPVOLUME_OUTER_DETAIL (pixels of error on screen),
/// MAPVOLUME_LOADS and MAPVOLUME_UPLOADS (concurrency).
struct StaticView {
    var name: String
    var inputs: StreamingInputs
    var settings: StreamingSettings
    var windowSize: CGSize
    var near: Float
    var far: Float

    /// The bridge selects detail as if the view were this many pixels tall
    /// (see `ViewState` in CNTileStreamer.mm), whatever the window is.
    private static let assumedViewportHeight = 2048.0

    /// A `StreamingSettings` detail value that means `pixels` of error in a
    /// window `windowHeight` points tall.
    static func detail(pixels: Double, windowHeight: Double) -> Double {
        pixels * assumedViewportHeight / windowHeight
    }

    /// The Ferry Building, from over the bay looking west at downtown,
    /// streaming 3 km around. Detail is the app's default, which assumes a
    /// 2048-pixel-tall view rather than this 900-point window.
    static let ferry: StaticView = {
        let focus = GeoCoordinate(latitude: 37.7955, longitude: -122.3937)
        return StaticView(name: "ferry",
                          inputs: StreamingInputs(anchor: StreamingAnchor(coordinate: focus),
                                                  lod: .orbit(heading: 3 * .pi / 2,
                                                              elevation: 35 * .pi / 180,
                                                              distance: 2500),
                                                  regionHeading: 3 * .pi / 2,
                                                  streamingRadius: 3000),
                          settings: .default,
                          windowSize: CGSize(width: 900, height: 900),
                          near: 1, far: 100_000)
    }()

    /// Downtown San Francisco in the foreground, then the bay, San Pablo Bay,
    /// Napa and the hills behind, out to the horizon: the camera of a Google
    /// Earth Web link, for comparing how fast the same view fills in.
    /// Google's link is `@37.84621441,-122.39504907,-3.00480709a,9744.84d,35y,6.10h,84.99t,0r`:
    /// look-at point, its altitude, range, vertical field of view, heading
    /// and tilt from straight down. The streamed region is a square around
    /// the look-at point, wide enough to cover the horizon ahead.
    static let bay: StaticView = {
        let size = CGSize(width: 1200, height: 800)
        let target = GeoCoordinate(latitude: 37.84621441, longitude: -122.39504907)
        let heading = 6.10259167 * Double.pi / 180
        var lod = LODCamera.orbit(heading: heading,
                                  elevation: (90 - 84.98672149) * .pi / 180,
                                  distance: 9744.84327601)
        lod.fieldOfView = 35 * .pi / 180
        lod.aspect = size.width / size.height
        var settings = StreamingSettings.default
        // On-screen pixels of error, not the default's 2048-pixel view.
        settings.detail = detail(pixels: 16, windowHeight: size.height)
        settings.outerDetail = detail(pixels: 64, windowHeight: size.height)
        return StaticView(name: "bay",
                          // Google's altitude is above sea level; the water
                          // here is about 32.7 m below the ellipsoid.
                          inputs: StreamingInputs(anchor: StreamingAnchor(coordinate: target, height: -3 - 32.7),
                                                  lod: lod,
                                                  regionHeading: heading,
                                                  streamingRadius: 150_000),
                          settings: settings,
                          windowSize: size,
                          near: 10, far: 400_000)
    }()

    /// The view named by MAPVOLUME_VIEW, with any streaming overrides.
    static func fromEnvironment() -> StaticView {
        let env = ProcessInfo.processInfo.environment
        #if os(tvOS)
        var view = env["MAPVOLUME_VIEW"] == "bay" ? bay : ferry
        view.windowSize = CGSize(width: 1920, height: 1080)
        view.inputs.lod.aspect = 1920.0 / 1080.0
        #else
        var view = env["MAPVOLUME_VIEW"] == "ferry" ? ferry : bay
        #endif
        func number(_ key: String) -> Double? { env[key].flatMap(Double.init) }
        if let radius = number("MAPVOLUME_RADIUS") { view.inputs.streamingRadius = radius }
        if let pixels = number("MAPVOLUME_DETAIL") {
            view.settings.detail = detail(pixels: pixels, windowHeight: view.windowSize.height)
        }
        if let pixels = number("MAPVOLUME_OUTER_DETAIL") {
            view.settings.outerDetail = detail(pixels: pixels, windowHeight: view.windowSize.height)
        }
        if let loads = number("MAPVOLUME_LOADS") { view.settings.simultaneousLoads = loads }
        if let uploads = number("MAPVOLUME_UPLOADS") { view.settings.uploadConcurrency = uploads }
        return view
    }
}

@MainActor
@Observable
final class StaticMap {
    let view = StaticView.fromEnvironment()
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

    init() {
        streaming = TileStreaming(inputs: view.inputs, settings: view.settings)
    }

    func attach(_ content: inout RealityViewCameraContent) {
        content.camera = .virtual
        // Tiles come placed in the anchor's level frame (x east, y up, z
        // south, metres), so the scene is that frame, unscaled.
        content.add(streaming.tilesRoot)
        content.add(makeCamera())

        streaming.start()
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.update(deltaTime: Float(event.deltaTime))
            }
        }
    }

    #if os(tvOS)
    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var inputs = streaming.inputs
        inputs.lod.aspect = size.width / size.height
        streaming.inputs = inputs
    }
    #endif

    private func update(deltaTime: Float) {
        streaming.update(deltaTime: deltaTime)
        elapsed += deltaTime
        if secondsToFirstTile == nil, streaming.stats.renderedTiles > 0 {
            secondsToFirstTile = elapsed
        }
        if secondsToComplete == nil, streaming.stats.renderedTiles > 0, streaming.loadProgress >= 100 {
            secondsToComplete = elapsed
            #if DEBUG
            print("[MapVolume] \(view.name): first tile \(String(format: "%.1f", secondsToFirstTile ?? 0)) s, loaded \(String(format: "%.1f", elapsed)) s, \(streaming.stats.renderedTiles) tiles, \(String(format: "%.1f", streaming.stats.networkMegabytes)) MB downloaded")
            #endif
        }
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

struct MapWindowView: View {
    @State private var map = StaticMap()

    private static func format(_ seconds: Float?) -> String {
        seconds.map { String(format: "%.1f s", $0) } ?? "…"
    }

    var body: some View {
        RealityView { content in
            map.attach(&content)
        }
        #if os(tvOS)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { map.resize(to: $0) }
        #else
        .frame(width: map.view.windowSize.width, height: map.view.windowSize.height)
        #endif
        .background(Color(red: 0.55, green: 0.7, blue: 0.85))
        .overlay(alignment: .topLeading) {
            Text("\(map.streaming.stats.renderedTiles) tiles · \(Int(map.streaming.loadProgress))% · \(map.framesPerSecond) fps · cache \(map.streaming.stats.cacheHits)/\(map.streaming.stats.revalidated)/\(map.streaming.stats.networkLoads) · first \(Self.format(map.secondsToFirstTile)) · done \(Self.format(map.secondsToComplete))")
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
