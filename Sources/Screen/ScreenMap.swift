import RealityKit
import SwiftUI

/// The map on a flat screen (macOS, and iOS next): the window's camera is
/// the navigation camera, flown with the keyboard or a game controller. The
/// navigation core, ground estimate and streaming are the same as on
/// visionOS; only the presentation (`ScreenView`) differs.
@MainActor
@Observable
final class ScreenMap {
    let streaming: TileStreaming
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
    @ObservationIgnored private var currentPlaceIndex: Int?
    /// Bumped per ground sample so a slow, older result can't win.
    @ObservationIgnored private var groundSampleGeneration = 0
    @ObservationIgnored private let cameraEntity = Entity()
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var aspect = 1.0
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var frameElapsed: Float = 0

    /// Vertical field of view, radians: the window camera's and the LOD
    /// camera's.
    static let fieldOfView = Double.pi / 4
    /// Lowest camera height above the estimated ground, metres.
    private static let minimumAltitude = 2.0

    /// Where to sample the ground first, and whether the start camera was
    /// framed on the ellipsoid, to be lifted by the ground found there.
    @ObservationIgnored private let startGround: (centre: GeoCoordinate, radius: Double, lifts: Bool)

    convenience init(place: Place, settings: StreamingSettings) {
        self.init(camera: ScreenView.framePlace(place, fieldOfView: Self.fieldOfView), settings: settings,
                  startGround: (place.coordinate, place.radius, true))
        currentPlaceIndex = PlaceLibrary.all.firstIndex(of: place)
    }

    init(camera: CameraPose, settings: StreamingSettings,
         startGround: (centre: GeoCoordinate, radius: Double, lifts: Bool)? = nil) {
        self.startGround = startGround ?? (camera.coordinate, 500, false)
        navigation = NavigationState(camera: camera)
        streaming = TileStreaming(inputs: ScreenView.streamingInputs(camera: camera, groundHeight: 0,
                                                                     fieldOfView: Self.fieldOfView, aspect: 1),
                                  settings: settings)
        navigation = flight.activate(navigation)
    }

    func attach(_ content: inout RealityViewCameraContent) {
        content.camera = .virtual
        content.add(streaming.tilesRoot)
        content.add(tracks.overlay.root)
        content.add(cameraEntity)
        applyView()
        streaming.start()
        sampleGround(around: startGround.centre, radius: startGround.radius, liftsCamera: startGround.lifts)
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.tick(deltaTime: Float(event.deltaTime))
            }
        }
    }

    /// Matches the LOD camera to the window and sets detail as pixels of
    /// error on this screen.
    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspect = size.width / size.height
        var settings = streaming.settings
        settings.detail = StaticView.detail(pixels: 16, windowHeight: size.height)
        settings.outerDetail = StaticView.detail(pixels: 64, windowHeight: size.height)
        streaming.settings = settings
        applyView()
    }

    // MARK: Places

    func go(to place: Place) {
        tracks.stopPlayback()
        tracks.markJump()
        currentPlaceIndex = PlaceLibrary.all.firstIndex(of: place)
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
        navigation = flight.activate(NavigationState(camera: first))
    }

    // MARK: Frame loop

    private func tick(deltaTime: Float) {
        guard streaming.isStreaming else { return }
        let dt = Double(deltaTime)
        if let played = tracks.advancePlayback(deltaTime: dt) {
            navigation.camera = played
            if navigation.headingLink == .linked { navigation.movementHeading = played.heading }
        }
        applyInput(deltaTime: dt)
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
            go(to: places[((currentPlaceIndex ?? -1) + 1) % places.count])
        case .previousPlace where !places.isEmpty:
            go(to: places[((currentPlaceIndex ?? 0) - 1 + places.count) % places.count])
        case .faceNorth where !tracks.isPlaying:
            navigation = NavigationOperations.faceNorth(navigation)
        default:
            break
        }
    }

    private var context: NavigationContext {
        NavigationContext(cameraGround: cameraGround.value,
                          minimumAltitude: Self.minimumAltitude,
                          maximumAltitude: streaming.settings.zoomOutLimitKilometres * 1_100)
    }

    // MARK: Placement

    /// Streams for the camera, then places the tiles and the camera entity.
    private func applyView() {
        let camera = navigation.camera
        streaming.inputs = ScreenView.streamingInputs(camera: camera, groundHeight: cameraGround.value,
                                                      fieldOfView: Self.fieldOfView, aspect: aspect)
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

/// The map in a window: the scene, its attribution and, optionally, a
/// status line. Hosts add their own controls around it.
struct ScreenMapView: View {
    let map: ScreenMap
    var showsStatus = true
    var creditLineLimit: Int? = 1
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
            if showsStatus {
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
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(map.streaming.stats.renderedTiles) tiles · \(Int(map.streaming.loadProgress))% · \(map.framesPerSecond) fps")
            Text(String(format: "%.5f, %.5f · %.0f m · heading %.0f° · pitch %.0f°",
                        camera.latitude, camera.longitude, camera.height,
                        camera.heading * 180 / .pi, camera.pitch * 180 / .pi))
            if map.keyboardConnected {
                Text(MapInput.screenKeyboardHint)
            }
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
