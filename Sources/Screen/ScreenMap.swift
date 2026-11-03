import RealityKit
import SwiftUI

/// The map on a flat screen (macOS and iOS): the window's camera is the
/// navigation camera, flown with touch, a mouse or trackpad, the keyboard or
/// a game controller. The navigation core, ground estimate and streaming are
/// the same as on visionOS; only the presentation (`ScreenView`) differs.
@MainActor
@Observable
final class ScreenMap {
    let streaming: TileStreaming
    /// What Settings edits, saved between launches. Streaming gets these
    /// with detail set for this screen's pixels instead.
    var settings: StreamingSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            applySettings()
        }
    }
    /// The camera, movement heading and heading link: the only stored
    /// navigation state.
    private(set) var navigation: NavigationState
    private(set) var framesPerSecond = 0
    private(set) var keyboardConnected = false
    private(set) var controllerName: String?
    /// Input from on-screen controls (iOS joysticks), merged with the
    /// keyboard and controller each frame.
    @ObservationIgnored var touchInput = MapInput()
    /// Recording, drawing and playing back camera tracks, shared with
    /// visionOS. While a track plays it has the camera, and movement input
    /// is ignored; going to a place stops it.
    let tracks = TrackSession()

    @ObservationIgnored private var flight = ModelFlightStyle()
    @ObservationIgnored private var cameraGround = CameraGround()
    @ObservationIgnored private var heldActions: Set<MapInput.Action> = []
    @ObservationIgnored private var currentPlaceID: String?
    /// Sampled again if there was no streamer to ask.
    @ObservationIgnored private var lastGroundSample: (centre: GeoCoordinate, radius: Double, liftsCamera: Bool)?
    /// Bumped per ground sample so a slow, older result can't win.
    @ObservationIgnored private var groundSampleGeneration = 0
    @ObservationIgnored private let cameraEntity = Entity()
    /// The tiles, overlay and camera, moved as one between the window's
    /// scene and a headset renderer (macOS, `HeadsetMap`).
    @ObservationIgnored let root = Entity()
    /// In the window's scene; holds `root` while the window shows the map.
    @ObservationIgnored private let windowHost = Entity()
    /// While a headset renders the map, it drives the frame loop and the
    /// window's scene updates no longer do.
    @ObservationIgnored private(set) var isInHeadset = false
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var viewportSize = SIMD2<Double>(1, 1)
    @ObservationIgnored private var touch = TouchState()
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var frameElapsed: Float = 0

    /// Vertical field of view, radians: the window camera's and the LOD
    /// camera's.
    static let fieldOfView = Double.pi / 4
    /// Lowest camera height above the estimated ground, metres.
    private static let minimumAltitude = 2.0
    /// Highest camera height above the estimated ground, metres: a view
    /// 10,000 km in half-width, roughly a hemisphere.
    private static let maximumAltitude = 11_000_000.0

    /// Where to sample the ground first, and whether the start camera was
    /// framed on the ellipsoid, to be lifted by the ground found there.
    @ObservationIgnored private let startGround: (centre: GeoCoordinate, radius: Double, lifts: Bool)

    convenience init(place: Place, settings: StreamingSettings) {
        self.init(camera: ScreenView.framePlace(place, fieldOfView: Self.fieldOfView), settings: settings,
                  startGround: (place.coordinate, place.radius, true))
        currentPlaceID = place.id
    }

    init(camera: CameraPose, settings: StreamingSettings,
         startGround: (centre: GeoCoordinate, radius: Double, lifts: Bool)? = nil) {
        self.startGround = startGround ?? (camera.coordinate, 500, false)
        self.settings = settings
        navigation = NavigationState(camera: camera)
        streaming = TileStreaming(inputs: ScreenView.streamingInputs(camera: camera, groundHeight: 0,
                                                                     fieldOfView: Self.fieldOfView, aspect: 1),
                                  settings: settings)
        navigation = flight.activate(navigation)
    }

    func attach(_ content: inout RealityViewCameraContent) {
        content.camera = .virtual
        root.addChild(streaming.tilesRoot)
        root.addChild(tracks.overlay.root)
        root.addChild(cameraEntity)
        if !isInHeadset { windowHost.addChild(root) }
        content.add(windowHost)
        applyView()
        streaming.start()
        sampleGround(around: startGround.centre, radius: startGround.radius, liftsCamera: startGround.lifts)
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.isInHeadset else { return }
                self.tick(deltaTime: Float(event.deltaTime))
            }
        }
    }

    /// Hands `root` to a headset renderer, which then calls `headsetTick`
    /// each frame; `leaveHeadset` gives it back to the window.
    func enterHeadset() -> Entity {
        isInHeadset = true
        root.removeFromParent()
        return root
    }

    func leaveHeadset() {
        guard isInHeadset else { return }
        isInHeadset = false
        root.removeFromParent()
        windowHost.addChild(root)
    }

    /// One frame while a headset renders the map.
    func headsetTick(deltaTime: Float) {
        guard isInHeadset else { return }
        tick(deltaTime: deltaTime)
    }

    /// The navigation camera's heading, radians clockwise from north: the
    /// headset turns the level scene by it, leaving pitch to the head.
    var heading: Double { navigation.camera.heading }

    /// Near and far clip distances for the current camera, metres.
    var clipping: (near: Double, far: Double) {
        ScreenView.clipping(altitude: navigation.camera.height - cameraGround.value)
    }

    /// Matches the LOD camera to the window and sets detail as pixels of
    /// error on this screen.
    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewportSize = SIMD2(size.width, size.height)
        applySettings()
        applyView()
    }

    private func applySettings() {
        var settings = settings
        settings.detail = StaticView.detail(pixels: 16, windowHeight: viewportSize.y)
        settings.outerDetail = StaticView.detail(pixels: 64, windowHeight: viewportSize.y)
        streaming.settings = settings
    }

    // MARK: Places

    func go(to place: Place) {
        touch = TouchState()
        tracks.stopPlayback()
        tracks.markJump()
        currentPlaceID = place.id
        let camera = ScreenView.framePlace(place, fieldOfView: Self.fieldOfView)
        navigation = flight.activate(NavigationState(camera: camera))
        cameraGround.reset(to: 0)
        // Framed on the ellipsoid; lift it by the ground there once known.
        sampleGround(around: place.coordinate, radius: place.radius, liftsCamera: true)
    }

    /// Samples the ground around `centre` for the ground estimate. With
    /// `liftsCamera`, the camera rises by what it finds, so a place framed
    /// on the ellipsoid ends up framed on the ground.
    private func sampleGround(around centre: GeoCoordinate, radius: Double, liftsCamera: Bool) {
        lastGroundSample = (centre, radius, liftsCamera)
        groundSampleGeneration += 1
        let generation = groundSampleGeneration
        let assumed = cameraGround.value
        streaming.sampleGroundHeight(around: centre, radius: radius) { [weak self] height in
            MainActor.assumeIsolated {
                guard let self, generation == self.groundSampleGeneration, height.isFinite else { return }
                let ground = min(max(height, -500), 9_000)
                if liftsCamera { self.navigation.camera.height += ground - assumed }
                self.cameraGround.reset(to: ground)
            }
        }
    }

    /// Plays the latest track from its first pose.
    func startPlayback() {
        guard let first = tracks.startPlayback() else { return }
        touch = TouchState()
        navigation = flight.activate(NavigationState(camera: first))
    }

    // MARK: Frame loop

    private func tick(deltaTime: Float) {
        guard streaming.isStreaming else {
            // Waiting for a key. Once there is one, the ground sample that
            // had no streamer to ask can run.
            streaming.updateKey()
            if streaming.isStreaming, let sample = lastGroundSample {
                sampleGround(around: sample.centre, radius: sample.radius, liftsCamera: sample.liftsCamera)
            }
            return
        }
        let dt = Double(deltaTime)
        if let played = tracks.advancePlayback(deltaTime: dt) {
            navigation.camera = played
            if navigation.headingLink == .linked { navigation.movementHeading = played.heading }
        }
        applyInput(deltaTime: dt)
        applyGlide(deltaTime: dt)
        cameraGround.update(camera: navigation.camera, rendered: streaming.renderedHeightRanges(), deltaTime: dt)
        tracks.record(navigation.camera)
        applyView()
        streaming.update(deltaTime: deltaTime)
        countFrame(deltaTime)
    }

    private func applyInput(deltaTime: Double) {
        let connected = MapInput.isKeyboardConnected
        if keyboardConnected != connected { keyboardConnected = connected }
        let controller = MapInput.controller?.vendorName ?? (MapInput.controller == nil ? nil : "Controller")
        if controllerName != controller { controllerName = controller }

        var input = MapInput.current()
        input.merge(touchInput)
        // Buttons act once, on the frame they go down.
        for action in input.held.subtracting(heldActions) {
            perform(action)
        }
        heldActions = input.held

        guard input.isMoving, !tracks.isPlaying else { return }
        flight.dollySurfaceHeight = cameraGround.value
        navigation = flight.step(navigation, input: input.controlInput, deltaTime: deltaTime, context: context)
    }

    private func perform(_ action: MapInput.Action) {
        let places = PlaceLibrary.all
        switch action {
        case .nextPlace where !places.isEmpty:
            go(to: PlaceLibrary.place(in: places, stepping: 1, from: currentPlaceID))
        case .previousPlace where !places.isEmpty:
            go(to: PlaceLibrary.place(in: places, stepping: -1, from: currentPlaceID))
        case .faceNorth where !tracks.isPlaying:
            navigation = NavigationOperations.faceNorth(navigation)
        default:
            break
        }
    }

    private var context: NavigationContext {
        NavigationContext(cameraGround: cameraGround.value,
                          minimumAltitude: Self.minimumAltitude,
                          maximumAltitude: Self.maximumAltitude)
    }

    // MARK: Placement

    /// Streams for the camera, then places the tiles and the camera entity.
    private func applyView() {
        let camera = navigation.camera
        streaming.inputs = ScreenView.streamingInputs(camera: camera, groundHeight: cameraGround.value,
                                                      fieldOfView: Self.fieldOfView, aspect: viewport.aspect)
        let georeference = ScreenView.georeference(camera: camera)
        streaming.tilesRoot.transform = Transform(georeference.placement(of: streaming.inputs.anchor))
        let altitude = max(camera.height - cameraGround.value, Self.minimumAltitude)
        tracks.overlay.update(georeference: georeference,
                              worldRadius: TrackOverlay.screenRadiusPerAltitude * altitude)

        let (near, far) = ScreenView.clipping(altitude: camera.height - cameraGround.value)
        cameraEntity.components.set(PerspectiveCameraComponent(near: Float(near), far: Float(far),
                                                               fieldOfViewInDegrees: Float(Self.fieldOfView * 180 / .pi)))
        cameraEntity.orientation = simd_quatf(vector: SIMD4<Float>(ScreenView.cameraOrientation(camera: camera).vector))
        cameraEntity.position = .zero
    }

    // MARK: Touch

    /// Direct manipulation, in screen points of the map view. The ground
    /// you touch stays under your finger (see ScreenGestures); a track
    /// playing has the camera, so these do nothing meanwhile.
    private struct TouchState {
        /// The ground under the finger, or between two fingers, ECEF.
        var grab: SIMD3<Double>?
        var twoFingers = TwoFingerClassifier()
        var lastScale = 1.0
        var lastRotation = 0.0
        var lastTranslationY = 0.0
        /// What a two-finger tilt swings about, the ground at the centre.
        var tiltPivot: SIMD3<Double>?
        /// After a flick: metres per second forward and right of the
        /// movement heading, dying away.
        var coast = SIMD2<Double>.zero
        /// A tap's zoom, eased over a moment.
        var zoom: (pivot: SIMD3<Double>, rate: Double, remaining: Double)?
    }

    /// How long a tap's zoom takes, seconds.
    private static let zoomDuration = 0.25
    /// Tilt, radians for the fingers crossing the screen's height.
    private static let tiltPerScreen = 2.0
    /// Turn, radians for the pointer crossing the screen's width.
    private static let turnPerScreen = Double.pi

    private var viewport: ScreenViewport {
        ScreenViewport(size: viewportSize, fieldOfView: Self.fieldOfView)
    }

    private func groundPoint(under point: SIMD2<Double>) -> SIMD3<Double>? {
        ScreenGestures.groundPoint(camera: navigation.camera, point: point, viewport: viewport,
                                   groundHeight: cameraGround.value)
    }

    private func panned(_ state: NavigationState, to point: SIMD2<Double>) -> NavigationState {
        guard let grab = touch.grab else { return state }
        return ScreenGestures.pan(state, grab: grab, to: point, viewport: viewport,
                                  groundHeight: cameraGround.value)
    }

    func beginDrag(at point: SIMD2<Double>) {
        guard !tracks.isPlaying else { return }
        touch = TouchState()
        touch.grab = groundPoint(under: point)
    }

    func drag(to point: SIMD2<Double>) {
        guard !tracks.isPlaying else { return }
        navigation = panned(navigation, to: point)
    }

    /// `velocity` is points per second: a flick keeps the map coasting.
    func endDrag(at point: SIMD2<Double>, velocity: SIMD2<Double>) {
        defer { touch.grab = nil }
        guard !tracks.isPlaying, simd_length(velocity) > 150,
              let from = groundPoint(under: point),
              let to = groundPoint(under: point + velocity * 0.05)
        else { return }
        let (forward, right) = ScreenGestures.alongMovement(navigation, (from - to) / 0.05)
        let coast = SIMD2(forward, right)
        let fastest = 3 * context.altitude(of: navigation.camera)
        touch.coast = simd_length(coast) > fastest ? simd_normalize(coast) * fastest : coast
    }

    func beginTwoFingers(at centre: SIMD2<Double>) {
        guard !tracks.isPlaying else { return }
        touch = TouchState()
        touch.grab = groundPoint(under: centre)
    }

    /// `translation`, `scale` and `rotation` are since the fingers came
    /// down; `rotation` is radians clockwise on screen.
    func twoFingers(at centre: SIMD2<Double>, translation: SIMD2<Double>, scale: Double, rotation: Double) {
        guard !tracks.isPlaying else { return }
        switch touch.twoFingers.update(translation: translation, scale: scale, rotation: rotation) {
        case .undecided:
            break
        case .tilt:
            if touch.tiltPivot == nil { touch.tiltPivot = groundPoint(under: viewport.centre) }
            guard let pivot = touch.tiltPivot else { return }
            let rise = touch.lastTranslationY - translation.y
            touch.lastTranslationY = translation.y
            navigation = NavigationOperations.tilt(navigation, about: pivot,
                                                   by: rise / viewportSize.y * Self.tiltPerScreen,
                                                   range: (-Double.pi / 2)...ScreenGestures.levelestTilt,
                                                   context: context)
        case .follow:
            guard let grab = touch.grab else { return }
            var state = ScreenGestures.zoom(navigation, about: grab, scale: scale / touch.lastScale, context: context)
            // Turning the map clockwise swings the camera the other way.
            state = NavigationOperations.orbit(state, about: grab, by: touch.lastRotation - rotation, context: context)
            touch.lastScale = scale
            touch.lastRotation = rotation
            navigation = panned(state, to: centre)
        }
    }

    func endTwoFingers() {
        touch.grab = nil
    }

    /// Zooms by `factor` about the ground under a point, a moment at a
    /// time: a double tap (2), a two-finger tap (0.5).
    func zoom(at point: SIMD2<Double>, by factor: Double) {
        guard !tracks.isPlaying, let pivot = groundPoint(under: point) else { return }
        // A scroll asks again before the last step is done; keep what's left.
        let unfinished = touch.zoom.map { $0.rate * $0.remaining } ?? 0
        touch = TouchState()
        touch.zoom = (pivot, (log(factor) + unfinished) / Self.zoomDuration, Self.zoomDuration)
    }

    /// Moves the map by `delta` screen points with nothing to hold on to: a
    /// trackpad scroll, measured at the middle of the view.
    func scroll(by delta: SIMD2<Double>) {
        guard !tracks.isPlaying, let grab = groundPoint(under: viewport.centre) else { return }
        touch = TouchState()
        navigation = ScreenGestures.pan(navigation, grab: grab, to: viewport.centre + delta, viewport: viewport,
                                        groundHeight: cameraGround.value)
    }

    /// Turns and tilts about the ground at the middle of the view: `drag`
    /// is points moved, right turning the camera clockwise (the near ground
    /// follows) and up levelling the view.
    func orbit(by drag: SIMD2<Double>) {
        guard !tracks.isPlaying, let pivot = groundPoint(under: viewport.centre) else { return }
        touch = TouchState()
        var state = NavigationOperations.orbit(navigation, about: pivot,
                                               by: drag.x / viewportSize.x * Self.turnPerScreen, context: context)
        state = NavigationOperations.tilt(state, about: pivot, by: -drag.y / viewportSize.y * Self.tiltPerScreen,
                                          range: (-Double.pi / 2)...ScreenGestures.levelestTilt, context: context)
        navigation = state
    }

    func beginZoomDrag(at point: SIMD2<Double>) {
        guard !tracks.isPlaying else { return }
        touch = TouchState()
        touch.grab = groundPoint(under: point)
    }

    /// Zooms directly by `scale` since the last call, about the ground the
    /// drag began on: a double tap held and dragged.
    func zoomDrag(by scale: Double) {
        guard !tracks.isPlaying, let grab = touch.grab else { return }
        navigation = ScreenGestures.zoom(navigation, about: grab, scale: scale, context: context)
    }

    func endZoomDrag() {
        touch.grab = nil
    }

    /// What's left of a flick and a tap's zoom.
    private func applyGlide(deltaTime: Double) {
        guard !tracks.isPlaying else { return }
        if touch.coast != .zero {
            let step = touch.coast * deltaTime
            navigation = NavigationOperations.move(navigation, forward: step.x, right: step.y)
            touch.coast *= exp(-3 * deltaTime)
            if simd_length(touch.coast) < 0.02 * context.altitude(of: navigation.camera) {
                touch.coast = .zero
            }
        }
        if var zoom = touch.zoom {
            let step = min(deltaTime, zoom.remaining)
            navigation = ScreenGestures.zoom(navigation, about: zoom.pivot, scale: exp(zoom.rate * step),
                                             context: context)
            zoom.remaining -= step
            touch.zoom = zoom.remaining > 0 ? zoom : nil
        }
    }

    private func countFrame(_ deltaTime: Float) {
        frameCount += 1
        frameElapsed += deltaTime
        if frameElapsed >= 1 {
            framesPerSecond = Int((Float(frameCount) / frameElapsed).rounded())
            frameCount = 0
            frameElapsed = 0
        }
    }
}

/// The map in a window: the scene, its attribution, and input hints and
/// (if turned on in Settings) stats. Hosts add their own controls around it.
struct ScreenMapView: View {
    let map: ScreenMap
    var creditLineLimit: Int? = 1
    @AppStorage(ViewPreferences.showsStatsKey) private var showsStats = false
    @State private var viewportSize: CGSize = .zero

    var body: some View {
        // The map fills the screen, under bars and around the notch; the
        // controls over it stay in the safe area.
        ZStack {
            RealityView { content in
                map.resize(to: viewportSize)
                map.attach(&content)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                viewportSize = $0
                map.resize(to: $0)
            }
            .background(Color(red: 0.55, green: 0.7, blue: 0.85))
            .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            if showsStats || map.keyboardConnected || map.controllerName != nil {
                status
            }
        }
        .overlay(alignment: .bottom) {
            AttributionBar(streaming: map.streaming, creditLineLimit: creditLineLimit)
                .padding(8)
        }
    }

    private var status: some View {
        let camera = map.navigation.camera
        let stats = map.streaming.stats
        return VStack(alignment: .leading, spacing: 2) {
            if showsStats {
                Text("\(stats.renderedTiles) tiles · \(stats.entities) entities · \(Int(map.streaming.loadProgress))% · \(map.framesPerSecond) fps")
                Text(stats.requestsSummary)
                Text(String(format: "%.5f, %.5f · %.0f m · heading %.0f° · pitch %.0f°",
                            camera.latitude, camera.longitude, camera.height,
                            camera.heading * 180 / .pi, camera.pitch * 180 / .pi))
            }
            if map.keyboardConnected {
                Text(MapInput.screenKeyboardHint)
            }
            Text(MapInput.pointerHint)
            if map.controllerName != nil {
                Text(MapInput.controllerHint)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(6)
        .background(.black.opacity(0.5), in: .rect(cornerRadius: 6))
        .foregroundStyle(.white)
        .padding(8)
    }
}

private extension ScreenView {
    /// A place framed on the ellipsoid, from its radius and heading.
    static func framePlace(_ place: Place, fieldOfView: Double) -> CameraPose {
        framePlace(centre: place.coordinate, radius: max(place.radius, 50),
                   heading: place.heading * .pi / 180, fieldOfView: fieldOfView)
    }
}
