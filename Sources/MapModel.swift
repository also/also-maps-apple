import Foundation
import Observation
import RealityKit
import SwiftUI
import UIKit

/// Navigation and presentation for the map. The camera is the state
/// (`navigation`); each host shows it through the eye-level placement, which
/// puts the camera at the design eye point and the ground beneath it on the
/// host's base plane, level unless the tilt tips it. Tiles come from
/// `streaming`.
@MainActor
@Observable
final class MapModel {
    /// Volume extents in metres (width, height, depth).
    nonisolated static let volumeSize = MapPresentation.volumeSize

    /// Where the app starts: the Ferry Building, 600 m across the volume.
    static let defaultPlace = Place(id: "default", name: "San Francisco",
                                    latitude: 37.7955, longitude: -122.3937, radius: 600)

    /// The room placement: map frame → the host's reference space. Lives
    /// under whichever host's anchor matches the current presentation.
    let placementRoot = Entity()
    /// The map frame: tiles plus the gesture target.
    let root = Entity()
    /// Invisible slab that receives drag, pinch and twist gestures.
    let gestureTarget = Entity()

    /// The tiles, their credits and stats.
    let streaming: TileStreaming

    var settings: StreamingSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            // A new source drops every tile, held or not.
            if settings.tileSource != oldValue.tileSource, tilesHeld { setTilesHeld(false) }
            streaming.settings = settings
            layOutGestureTarget()
            requestGroundSample()
            applyView()
        }
    }

    /// The host showing the map. Switching keeps the camera (and any hold);
    /// only the room transform changes.
    var presentation = MapPresentation.volume {
        didSet {
            guard presentation != oldValue else { return }
            stopPlayback()
            endManipulation()
            reparentRoot()
            layOutGestureTarget()
            applyView()
        }
    }

    /// Map frame → reference space. Identity until room placement controls
    /// exist; navigation never changes it.
    var roomPlacement = RoomPlacement.identity {
        didSet { applyRoomPlacement() }
    }

    private(set) var keyboardConnected = false
    /// Name of the connected game controller, if any.
    private(set) var controllerName: String?
    /// Whether the volume (map + controls) window is open. In an immersive mode
    /// it can be closed while the immersive space stays up.
    var volumeIsOpen = false
    /// Immersive modes hide passthrough and the system environment: only the
    /// map is shown. Applies live to an open immersive space.
    var fullImmersion = false
    /// The immersive mode is drawn by the app's Metal renderer
    /// (MetalImmersiveContent) instead of RealityKit, per Settings. Read when
    /// the immersive space opens.
    var drawsImmersiveWithMetal: Bool { ViewPreferences.drawsWithMetal }

    // MARK: Navigation state

    /// The camera, movement heading and heading link. The only stored
    /// navigation state.
    private(set) var navigation: NavigationState
    private var flight = ModelFlightStyle()
    /// Drone mode's tilt assist: the map tilts toward you as you climb, from
    /// none below 50 km to the host's full tilt by 500 km. Off, the map
    /// stays level.
    var tiltFollowsAltitude = true
    /// Lowest camera height above the estimated ground in room hosts.
    private static let minimumAltitude = 55.0
    /// Highest camera height above the estimated ground, metres: a view
    /// 10,000 km in half-width, roughly a hemisphere.
    private static let maximumAltitude = 11_000_000.0

    // Ground estimates: the placement ground, put
    // on the base plane, and the ground under the camera, for speed and
    // limits.
    private var placementGround = EasedHeight(0)
    private var cameraGround = CameraGround()
    /// Bumped per sample request so a slow, older result can't win.
    private var groundSampleGeneration = 0
    private var wasMoving = false
    /// A place's framing assumes ground at 0 m until the first sample there;
    /// that sample moves the camera with the ground instead of rescaling.
    private var placeAwaitsGround = true

    /// The current framing, set by `applyView`.
    private var framing: AdaptiveModel.Framing?

    /// Immersive only, for testing: the world stays at human scale (1:1) at
    /// every altitude, with the camera on the eye and the ground wherever
    /// height puts it, instead of scaling so the ground meets the floor.
    var humanScale = false {
        didSet {
            guard humanScale != oldValue else { return }
            endManipulation()
            applyView()
        }
    }

    private var isImmersive: Bool { presentation.host == .immersive }

    /// The framing for `camera` in the current host: level unless the tilt
    /// assist tips it, by an amount that depends only on where the camera is.
    private func frame(_ camera: CameraPose) -> AdaptiveModel.Framing {
        framer(camera)
    }

    /// `frame`, with the current host, ground and settings captured.
    private var framer: (CameraPose) -> AdaptiveModel.Framing {
        let room = room, ground = placementGround.value, tiltFollowsAltitude = tiltFollowsAltitude
        let fixedScale: Double? = humanScale && isImmersive ? 1 : nil
        return { camera in
            let weight = tiltFollowsAltitude ? EyeLevelModel.tiltWeight(for: camera) : 0
            return EyeLevelModel.framing(camera: camera, room: room, groundHeight: ground,
                                         tiltWeight: weight, fixedScale: fixedScale)
        }
    }

    // MARK: Tiles held

    /// Held tiles: streaming keeps the inputs it had when the hold began, so
    /// you fly through what's loaded while nothing new is requested.
    private(set) var tilesHeld = false
    /// The authoritative held snapshot.
    private var heldInputs: StreamingInputs?

    // MARK: Gestures

    private enum GestureKind: Hashable { case drag, magnify, rotate }

    /// One anchored manipulation: drag, pinch and twist compose into a
    /// single solve that keeps the grabbed point under the hand.
    private struct Manipulation {
        /// Where the first gesture started, map frame.
        var start: SIMD3<Double>
        /// The world point that was there, ECEF.
        var grab: SIMD3<Double>
        var startPose: CameraPose
        var startScale: Double
        /// The latest solution, the next solve's starting guess.
        var pose: CameraPose
        var starts: [GestureKind: SIMD3<Float>] = [:]
        var translation = SIMD3<Double>.zero
        var magnification = 1.0
        var twist = 0.0
    }
    private var manipulation: Manipulation?
    private var lastMagnifyUpdate = Date.distantPast

    /// One anchor per host scene; `placementRoot` moves between them.
    private var anchors: [MapPresentation.Host: Entity] = [:]
    /// Both scenes deliver frame updates; only the presented host's are used.
    private var updateSubscriptions: [MapPresentation.Host: EventSubscription] = [:]
    private var heldActions: Set<MapInput.Action> = []
    /// The last place jumped to, for cycling.
    private var currentPlaceID: String?

    init() {
        let settings = StreamingSettings.load()
        self.settings = settings

        // Debug overrides: ALSOMAPS_LAT/_LON/_RADIUS/_HEADING pick the
        // starting view, and ALSOMAPS_TILESET_URL streams any 3D Tiles
        // tileset instead of Google's, no key needed.
        let env = ProcessInfo.processInfo.environment
        var place = Self.defaultPlace
        place.latitude = env["ALSOMAPS_LAT"].flatMap(Double.init) ?? place.latitude
        place.longitude = env["ALSOMAPS_LON"].flatMap(Double.init) ?? place.longitude
        place.radius = env["ALSOMAPS_RADIUS"].flatMap(Double.init) ?? place.radius
        place.heading = env["ALSOMAPS_HEADING"].flatMap(Double.init) ?? place.heading
        let camera = Self.framing(place, in: .volume, groundHeight: 0, tiltFollowsAltitude: true)
        navigation = ModelFlightStyle().activate(NavigationState(camera: camera))

        streaming = TileStreaming(inputs: StreamingInputs(anchor: StreamingAnchor(coordinate: place.coordinate)),
                                  settings: settings)
        placementRoot.addChild(root)
        root.addChild(debugMarkers)
        debugMarkers.isEnabled = false
        root.addChild(streaming.tilesRoot)
        streaming.tilesRoot.addChild(tileBoundsOverlay.root)
        root.addChild(tracks.overlay.root)
        // Indirect only (look + pinch). Allowing direct input meant hands that
        // were merely inside the map's area counted as touching it and
        // dragged the map with no pinch at all.
        gestureTarget.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        root.addChild(gestureTarget)
        layOutGestureTarget()
    }

    /// Called from each host's RealityView. Adds that host's anchor, routes
    /// its frame updates here, and starts streaming the first time.
    func attach(_ content: RealityViewContent, host: MapPresentation.Host) {
        let anchor = Entity()
        anchor.name = "anchor-\(host)"
        content.add(anchor)
        anchors[host] = anchor
        updateSubscriptions[host] = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.presentation.host == host else { return }
                self.tick(deltaTime: Float(event.deltaTime))
            }
        }
        reparentRoot()
        start()
    }

    /// The Metal immersive space opened: tiles are built for it until it
    /// closes. Streaming restarts each way; tiles come back from the cache.
    func metalImmersiveDidOpen(_ metal: MetalTileRenderer) {
        streaming.customRasterHandler = metal.rasterHandler
        streaming.customTileHandler = metal.handler
        metalImmersiveIsOpen = true
    }

    func metalImmersiveDidClose() {
        metalImmersiveIsOpen = false
        streaming.customRasterHandler = nil
        streaming.customTileHandler = nil
        immersiveSpaceDidClose()
    }

    /// The open immersive space is the Metal one, which can't show SwiftUI
    /// in the scene: the volume keeps the attribution, and there's no Show
    /// Controls panel to fall back on if it's closed.
    private(set) var metalImmersiveIsOpen = false

    /// The Metal immersive space drives the frame loop itself instead of a
    /// RealityView: one tick per frame it draws.
    func metalImmersiveTick(deltaTime: Float) {
        start()
        guard presentation.host == .immersive else { return }
        tick(deltaTime: deltaTime)
    }

    /// Anchor frame → the immersive space's origin: where the tiles go, for a
    /// renderer outside RealityKit.
    var tilesInImmersiveSpace: simd_float4x4 {
        placementRoot.transform.matrix * root.transform.matrix * streaming.tilesRoot.transform.matrix
    }

    /// The track's frame → the immersive space's origin, as for the tiles.
    var trackInImmersiveSpace: simd_float4x4 {
        placementRoot.transform.matrix * root.transform.matrix * tracks.overlay.root.transform.matrix
    }

    /// The volume went away (closed, or replaced by a blocking notice). It no
    /// longer drives streaming; opening it attaches again.
    func volumeDidClose() {
        volumeIsOpen = false
        updateSubscriptions[.volume] = nil
    }

    /// The immersive space went away (dismissed by us or the system).
    func immersiveSpaceDidClose() {
        measuredEye = nil
        anchors[.immersive] = nil
        updateSubscriptions[.immersive] = nil
        if presentation.host == .immersive { presentation = .volume }
    }

    private func reparentRoot() {
        if let anchor = anchors[presentation.host], placementRoot.parent !== anchor {
            anchor.addChild(placementRoot)
        }
    }

    private func applyRoomPlacement() {
        placementRoot.transform = Transform(roomPlacement.similarity)
    }

    /// The gesture target is a thin slab at ground level covering the shown
    /// square. Gaze passes through terrain and buildings (they have no
    /// collision) to the slab, while looking past the map's edges or over it
    /// no longer hits an invisible box.
    /// How far the immersive gesture slab reaches from the map's centre
    /// point, metres in the room.
    private static let immersiveGestureHalfWidth = 50.0

    private func layOutGestureTarget() {
        // Immersive: wide enough to pinch anywhere nearby on the map.
        let halfWidth = presentation.host == .immersive
            ? max(room.contentHalfWidth, Self.immersiveGestureHalfWidth)
            : room.contentHalfWidth
        let width = Float(2 * halfWidth)
        let thickness = Float(0.02 * presentation.magnification)
        gestureTarget.components.set(CollisionComponent(shapes: [
            .generateBox(size: [width, thickness, width])
        ]))
    }

    private var started = false

    private func start() {
        guard !started else { return }
        started = true
        streaming.start()
        applyView()
        requestGroundSample()

        // Debug: ALSOMAPS_PLACE=<id from Places.json> starts at that place.
        let env = ProcessInfo.processInfo.environment
        if let id = env["ALSOMAPS_PLACE"], let place = PlaceLibrary.all.first(where: { $0.id == id }) {
            go(to: place)
        }
    }

    // MARK: Places

    /// The camera that frames `place` in a host: its centre the view centre,
    /// `radius` metres of world across the host's half-width (half the
    /// volume, or the immersive space's magnified equivalent).
    private static func framing(_ place: Place, in presentation: MapPresentation,
                                groundHeight: Double, tiltFollowsAltitude: Bool) -> CameraPose {
        guard case let .room(room) = presentation.geometry else {
            preconditionFailure("visionOS hosts are rooms")
        }
        return EyeLevelModel.framePlace(centre: place.coordinate, radius: place.radius,
                                        heading: place.heading * .pi / 180,
                                        room: room, groundHeight: groundHeight,
                                        tiltFollowsAltitude: tiltFollowsAltitude)
    }

    /// Jumps to `place`: a camera framing its position, size and facing.
    /// Tiles for the old area unload as they fall outside the streamed
    /// region; the new area streams in.
    func go(to place: Place) {
        if tilesHeld { setTilesHeld(false) }
        stopPlayback()
        endManipulation()
        placeAwaitsGround = true
        currentPlaceID = place.id
        placementGround.reset(to: 0)
        cameraGround.reset(to: 0)
        framing = nil
        var camera = Self.framing(place, in: presentation, groundHeight: 0, tiltFollowsAltitude: tiltFollowsAltitude)
        camera.height = context.clampHeight(camera.height)
        navigation = flight.activate(NavigationState(camera: camera))
        tracks.markJump()
        applyView()
        requestGroundSample()
    }

    // MARK: Gestures

    /// `start` and `current` are the drag's scene positions, in metres.
    func drag(from start: SIMD3<Float>, to current: SIMD3<Float>) {
        guard beginOrContinue(.drag, at: start) else { return }
        // Content follows the hand, along the map's surface.
        var translation = SIMD3<Double>(roomPlacement.similarity.inverse.rotation.act(SIMD3<Double>(current - start)))
        let up = mapUp(at: manipulation!.grab)
        translation -= up * simd_dot(translation, up)
        manipulation?.translation = translation
        solveManipulation()
    }

    func endDrag() { end(.drag) }

    /// `magnification` is relative to the pinch's start, which was at
    /// `start` (scene metres).
    func magnify(by magnification: Double, startedAt start: SIMD3<Float>) {
        // A cancelled pinch never reaches endMagnify; a pause in updates
        // means this is a new pinch.
        if Date().timeIntervalSince(lastMagnifyUpdate) > 0.3 { manipulation?.starts[.magnify] = nil }
        lastMagnifyUpdate = Date()
        guard magnification > 0, beginOrContinue(.magnify, at: start) else { return }
        manipulation?.magnification = magnification
        solveManipulation()
    }

    func endMagnify() { end(.magnify) }

    /// `rotation` is the two-handed twist since the gesture began, already in
    /// scene space. The map turns with the hands, about where they pinched.
    func rotate(by rotation: simd_quatf, startedAt start: SIMD3<Float>) {
        guard beginOrContinue(.rotate, at: start) else { return }
        // Signed angle about +Y (counterclockwise seen from above): the
        // world turns that way, so the view heading turns clockwise.
        manipulation?.twist = 2 * atan2(Double(rotation.imag.y), Double(rotation.real))
        solveManipulation()
    }

    func endRotate() { end(.rotate) }

    /// Starts a manipulation, joins this gesture to the one in progress, or
    /// restarts if this kind of gesture began again somewhere new (visionOS
    /// can cancel a gesture without calling onEnded).
    private func beginOrContinue(_ kind: GestureKind, at start: SIMD3<Float>) -> Bool {
        // The played track has the camera; gestures are ignored.
        guard !tracks.isPlaying else { return false }
        if let existing = manipulation?.starts[kind], existing != start { endManipulation() }
        if manipulation == nil {
            guard let framing else { return false }
            let mapStart = roomPlacement.similarity.inverse.apply(SIMD3<Double>(start))
            manipulation = Manipulation(start: mapStart,
                                        grab: framing.georeference.ecef(map: mapStart),
                                        startPose: navigation.camera,
                                        startScale: framing.georeference.scale,
                                        pose: navigation.camera)
        }
        if manipulation?.starts[kind] == nil { manipulation?.starts[kind] = start }
        return true
    }

    private func end(_ kind: GestureKind) {
        manipulation?.starts[kind] = nil
        if manipulation?.starts.isEmpty == true { endManipulation() }
    }

    private func endManipulation() {
        guard manipulation != nil else { return }
        manipulation = nil
        requestGroundSample()
    }

    /// Solves for the camera that keeps the grabbed point under the hand at
    /// the pinched scale and twisted heading.
    private func solveManipulation() {
        guard let m = manipulation else { return }
        let target = AdaptiveModel.AnchorTarget(
            grab: m.grab,
            target: m.start + m.translation,
            scale: m.startScale * m.magnification,
            heading: m.startPose.heading + m.twist,
            headingOrigin: m.startPose.coordinate)
        let solution = AdaptiveModel.solve(target, from: m.pose, room: room, scaleSurface: placementGround.value,
                                           context: context, frame: frame)
        guard solution.error.isFinite else { return }
        var state = navigation
        let change = GeoMath.bearingChange(from: state.camera.coordinate, to: solution.pose.coordinate)
        state.camera = solution.pose
        state.movementHeading = state.headingLink == .linked
            ? solution.pose.heading
            : NavigationOperations.wrapped(state.movementHeading + change)
        guard withinHeldLimits(state) else { return }
        manipulation?.pose = solution.pose
        navigation = state
        applyView()
    }

    /// The map frame's up at a world point: the local vertical as shown.
    private func mapUp(at ecef: SIMD3<Double>) -> SIMD3<Double> {
        guard let framing else { return SIMD3(0, 1, 0) }
        let (coordinate, _) = Geodesy.geodetic(ecef)
        let up = Geodesy.enu(latitude: coordinate.latitude, longitude: coordinate.longitude).up
        return simd_normalize(framing.georeference.rotation.act(up))
    }

    // MARK: Frame loop

    private func tick(deltaTime: Float) {
        guard streaming.isStreaming else {
            // Waiting for a key. Once there is one, the ground sample that
            // had no streamer to ask can run.
            streaming.updateKey()
            if streaming.isStreaming { requestGroundSample() }
            return
        }
        let dt = Double(deltaTime)
        applyInput(deltaTime: dt)
        if tracks.isPlaying {
            advancePlayback(deltaTime: dt)
        }
        updateGround(deltaTime: dt)
        tracks.record(navigation.camera)
        applyView()
        if let framing {
            tracks.overlay.update(georeference: framing.georeference,
                                  worldRadius: TrackOverlay.roomRadius / framing.georeference.scale)
        }
        streaming.update(deltaTime: deltaTime)
        tileBoundsOverlay.update(inputs: streaming.inputs, scale: streaming.tilesRoot.transform.scale.x,
                                 thickness: 0.0006 * Float(presentation.magnification))
    }

    // MARK: Keyboard and controller

    private func applyInput(deltaTime: Double) {
        let connected = MapInput.isKeyboardConnected
        if keyboardConnected != connected { keyboardConnected = connected }
        let controller = MapInput.controller?.vendorName ?? (MapInput.controller == nil ? nil : "Controller")
        if controllerName != controller {
            controllerName = controller
            #if DEBUG
            print("[AlsoMaps] game controller: \(controller ?? "none")")
            #endif
        }

        let input = MapInput.current()

        // Buttons act once, on the frame they go down.
        for action in input.held.subtracting(heldActions) {
            perform(action)
        }
        heldActions = input.held

        // The played track has the camera; movement is ignored.
        guard input.isMoving, !tracks.isPlaying else {
            // Re-sample once movement settles, like the end of a drag.
            if wasMoving {
                wasMoving = false
                requestGroundSample()
            }
            return
        }
        wasMoving = true
        steer(with: ControlInput(move: input.move, turn: input.turn, climb: input.altitude,
                                 dolly: input.zoom, fast: input.fast),
              deltaTime: deltaTime)
    }

    /// Model flight. Zooming changes height with the view centre held in
    /// place, not along the camera's pitch, which room hosts don't show.
    private func steer(with input: ControlInput, deltaTime: Double) {
        flight.dollySurfaceHeight = placementGround.value
        let framer = framer
        flight.holdingViewCentre = { EyeLevelModel.pose($0, at: $1, holdingViewCentre: framer) }
        // Zoom works only below where the tilt starts. Not a property of the
        // world: it keeps zoom out of the tilt range, where the immersive
        // space's view centre isn't settled yet (#67).
        flight.zoomCeiling = EyeLevelModel.tiltStartAltitude
        // Turning, climbing and zooming first, limited (while held) by how
        // much of the held region they'd show; then travel, limited by how
        // far it goes from it.
        var looking = input
        looking.move = .zero
        var state = flight.step(navigation, input: looking, deltaTime: deltaTime, context: context)
        if withinHeldLimits(state, checking: [.size]) { navigation = state }

        guard input.move != .zero else { return }
        var moving = ControlInput()
        moving.move = input.move
        moving.fast = input.fast
        state = flight.step(navigation, input: moving, deltaTime: deltaTime, context: context)
        if withinHeldLimits(state, checking: [.travel]) { navigation = state }
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
        case .toggleTileHold:
            setTilesHeld(!tilesHeld)
        default:
            break
        }
    }

    // MARK: Limits

    private var context: NavigationContext {
        NavigationContext(cameraGround: cameraGround.value,
                          minimumAltitude: humanScale && isImmersive ? 1.6 : Self.minimumAltitude,
                          maximumAltitude: Self.maximumAltitude)
    }

    private enum HeldLimit { case travel, size }

    /// While tiles are held: travel keeps the georeference point within
    /// 1.5 × the held region of its centre, and climbing or zooming keeps the
    /// shown region within 3 × its size. A step that would break a checked
    /// limit, and make it worse, is refused, so you slide to a stop.
    private func withinHeldLimits(_ state: NavigationState,
                                  checking limits: Set<HeldLimit> = [.travel, .size]) -> Bool {
        guard tilesHeld, let held = heldInputs else { return true }
        let candidate = frame(state.camera)
        func ratio(_ limit: HeldLimit, _ framing: AdaptiveModel.Framing) -> Double {
            switch limit {
            case .travel:
                let g = Geodesy.geodetic(framing.georeferencePoint).coordinate
                return GeoMath.distance(from: g, to: held.anchor.coordinate) / (1.5 * held.streamingRadius)
            case .size:
                return framing.shownRadius(room) / (3 * held.streamingRadius)
            }
        }
        return limits.allSatisfy { limit in
            let after = ratio(limit, candidate)
            guard after > 1 else { return true }
            return framing.map { after < ratio(limit, $0) } ?? false
        }
    }

    // MARK: Ground

    /// The ground under the camera every frame (see `CameraGround`), for
    /// speed and limits.
    ///
    /// The placement ground (what sits on the base plane) comes only from
    /// the 3×3 surface sample once motion settles. Reading it from the
    /// loaded tiles continuously
    /// fed back on itself: a new height rescaled the map, which moved the LOD
    /// camera, which changed the tiles, which changed the height. Nothing
    /// changes it while tiles are held or during a gesture.

    private func updateGround(deltaTime: Double) {
        cameraGround.update(camera: navigation.camera, rendered: streaming.renderedHeightRanges(),
                            deltaTime: deltaTime)

        guard !tilesHeld, manipulation == nil else { return }
        placementGround.ease(deltaTime: deltaTime)
    }

    /// Above this half-width the terrain's detail no longer matters to where
    /// the ground sits, and a sample would load tiles across a huge region.
    private static let groundSampleRadius = 50_000.0

    /// The placement ground: the lowest of a 3×3 sample across the shown
    /// region once motion settles (live only; it may load tiles). A failed
    /// sample keeps the last estimate.
    private func requestGroundSample() {
        guard !tilesHeld, let framing else { return }
        let shown = framing.shownRadius(room)
        guard shown < Self.groundSampleRadius else { return }
        groundSampleGeneration += 1
        let generation = groundSampleGeneration
        let centre = Geodesy.geodetic(framing.georeferencePoint).coordinate
        streaming.sampleGroundHeight(around: centre, radius: shown) { [weak self] height in
            MainActor.assumeIsolated {
                guard let self, generation == self.groundSampleGeneration, !self.tilesHeld else { return }
                guard height.isFinite else { return }
                let ground = min(max(height, -500), 9_000)
                #if DEBUG
                print("[AlsoMaps] ground sample \(Int(ground)) m (was \(Int(self.placementGround.value)) m)")
                #endif
                if self.placeAwaitsGround {
                    // Places are framed relative to the ground.
                    self.placeAwaitsGround = false
                    self.navigation.camera.height += ground - self.placementGround.value
                    self.placementGround.reset(to: ground)
                } else {
                    self.placementGround.aim(at: ground)
                }
            }
        }
    }

    // MARK: Tiles held

    /// Holds the tiles (streaming keeps its current inputs) or releases them
    /// (streaming follows the camera again). Nothing visibly moves either way.
    func setTilesHeld(_ held: Bool) {
        guard held != tilesHeld else { return }
        if held {
            heldInputs = streaming.inputs
            tilesHeld = true
        } else {
            tilesHeld = false
            heldInputs = nil
            applyView()
            requestGroundSample()
        }
    }

    // MARK: Placement

    private var room: RoomGeometry {
        guard case var .room(room) = presentation.geometry else {
            preconditionFailure("visionOS hosts are rooms")
        }
        // Immersive: the eye is where the headset was when the space opened.
        if presentation.host == .immersive, let measuredEye {
            room.designEye = roomPlacement.similarity.inverse.apply(measuredEye)
        }
        return room
    }

    /// The headset's position in the immersive space when it opened, or nil
    /// (tracking unavailable, or not measured yet): the assumed eye is used.
    var measuredEye: SIMD3<Double>? {
        didSet {
            guard measuredEye != oldValue else { return }
            #if DEBUG
            if let measuredEye {
                print("[AlsoMaps] eye measured at \(String(format: "%.2f, %.2f, %.2f", measuredEye.x, measuredEye.y, measuredEye.z)) m")
            }
            #endif
            applyView()
        }
    }

    /// Places everything from the camera: the georeference, the tiles root
    /// relative to whichever anchor is streaming, the gesture slab and, while
    /// live, the streaming inputs. Called every frame.
    private func applyView() {
        guard streaming.isStreaming else { return }
        let framing = frame(navigation.camera)
        self.framing = framing

        if !tilesHeld {
            streaming.inputs = streamingInputs(for: framing)
        }
        let georeference = framing.georeference
        streaming.tilesRoot.transform = Transform(georeference.placement(of: streaming.inputs.anchor))

        // The slab lies on the ground at the view centre, level with the
        // ground there as shown.
        let g = Geodesy.geodetic(framing.georeferencePoint).coordinate
        let level = simd_quatd(Geodesy.anchorFrameRotation(latitude: g.latitude, longitude: g.longitude))
        gestureTarget.orientation = simd_quatf(vector: SIMD4<Float>((georeference.rotation * level).vector))
        gestureTarget.position = SIMD3<Float>(framing.placementPoint)
        updateDebugMarkers()
    }

    /// The area of interest each host streams by default, and the LOD camera
    /// at the design eye point.
    private func streamingInputs(for framing: AdaptiveModel.Framing) -> StreamingInputs {
        StreamingInputs.room(framing: framing, room: room, camera: navigation.camera,
                             policy: presentation.areaPolicy(settings), groundHeight: placementGround.value)
    }

    // MARK: Tracks

    /// Recording, drawing and playing back camera tracks, shared with the
    /// flat-screen map. Playback here also releases held tiles, ends any
    /// gesture and stops the framing assists; gestures and keyboard or
    /// controller movement are ignored while it plays, and jumping to a
    /// place, restoring a view or switching presentation stops it.
    let tracks = TrackSession()
    @ObservationIgnored private var lastPlaybackGroundSample: TimeInterval = 0

    var isRecordingTrack: Bool { tracks.isRecording }
    var latestTrack: URL? { tracks.latestTrack }
    func startTrack() { tracks.startRecording() }
    func stopTrack() { tracks.stopRecording() }
    func flushTrack() { tracks.flush() }

    var showsTrack: Bool {
        get { tracks.showsTrack }
        set { tracks.showsTrack = newValue }
    }

    var isPlayingTrack: Bool { tracks.isPlaying }
    var playbackElapsed: Int { tracks.playbackElapsed }
    var playbackDuration: Int { tracks.playbackDuration }

    /// Plays the latest track from the start.
    func startPlayback() {
        guard let first = tracks.startPlayback() else { return }
        if tilesHeld { setTilesHeld(false) }
        endManipulation()
        // Nothing but the track moves the camera: no ground sample lifting a
        // place's framing.
        placeAwaitsGround = false
        lastPlaybackGroundSample = 0
        framing = nil
        setPlayedCamera(first)
        applyView()
        requestGroundSample()
    }

    /// Stops playback, leaving the camera where it is.
    func stopPlayback() {
        guard tracks.isPlaying else { return }
        tracks.stopPlayback()
        requestGroundSample()
    }

    private func advancePlayback(deltaTime: Double) {
        guard let pose = tracks.advancePlayback(deltaTime: deltaTime) else { return }
        setPlayedCamera(pose)
        // The ground estimates otherwise wait for motion to settle.
        if !tracks.isPlaying || tracks.playbackTime - lastPlaybackGroundSample >= 2 {
            lastPlaybackGroundSample = tracks.playbackTime
            requestGroundSample()
        }
    }

    private func setPlayedCamera(_ camera: CameraPose) {
        var state = navigation
        state.camera = camera
        if state.headingLink == .linked { state.movementHeading = camera.heading }
        navigation = state
    }

    // MARK: View state

    func captureState() -> MapViewState {
        MapViewState(navigation: navigation,
                     rayHeight: placementGround.value,
                     envelopeHeight: placementGround.value,
                     host: presentation.id,
                     roomPlacement: roomPlacement,
                     heldStreaming: tilesHeld ? heldInputs : nil,
                     settings: settings)
    }

    /// Restores a captured view. The caller switches to its host first (that
    /// may need to open the immersive space). Ground estimates come back as
    /// captured, so the view does too.
    func restore(_ state: MapViewState) {
        if tilesHeld { setTilesHeld(false) }
        stopPlayback()
        endManipulation()
        settings = state.settings
        groundSampleGeneration += 1  // Drop any sample in flight.
        placeAwaitsGround = false
        // The ray estimate was always a sample; states saved before the
        // volume moved to eye-level placement can have a curvature envelope
        // tens of kilometres below the ground in `envelope`.
        placementGround.reset(to: state.groundEstimate.ray)
        roomPlacement = state.roomPlacement.placement
        navigation = state.navigationState
        tracks.markJump()
        framing = nil
        if let held = state.heldStreaming {
            streaming.inputs = held
            heldInputs = held
            tilesHeld = true
        }
        applyView()
        #if DEBUG
        print("[AlsoMaps] restored view state: \(captureState().json())")
        #endif
    }

    // MARK: Debug markers

    /// Posts at the ground beneath the camera (red: where you are), the
    /// georeference point (blue: what's on the placement point) and the
    /// area of interest's centre (green), in the map frame.
    var showsDebugMarkers = false {
        didSet { updateDebugMarkers() }
    }
    private let debugMarkers = Entity()

    /// Wireframes of each drawn tile's bounding box, the area of interest
    /// and the LOD camera's view. See TileBoundsOverlay.
    var showsTileBounds = false {
        didSet {
            streaming.showsTileBounds = showsTileBounds
            tileBoundsOverlay.isEnabled = showsTileBounds
        }
    }
    private let tileBoundsOverlay = TileBoundsOverlay()

    private func updateDebugMarkers() {
        debugMarkers.isEnabled = showsDebugMarkers
        guard showsDebugMarkers, let framing else { return }
        if debugMarkers.children.isEmpty {
            func post(_ color: UIColor) -> ModelEntity {
                var material = UnlitMaterial()
                material.color = .init(tint: color)
                return ModelEntity(mesh: .generateCylinder(height: 1, radius: 1), materials: [material])
            }
            debugMarkers.addChild(post(.systemRed))    // beneath the camera
            debugMarkers.addChild(post(.systemBlue))   // georeference point
            debugMarkers.addChild(post(.systemGreen))  // area of interest
        }
        let georeference = framing.georeference
        let camera = navigation.camera
        let anchor = streaming.inputs.anchor
        let points = [
            Geodesy.ecef(camera.coordinate, height: cameraGround.value),
            framing.georeferencePoint,
            Geodesy.ecef(anchor.coordinate, height: anchor.height),
        ]
        let size = Float(presentation.magnification)
        let height = 0.25 * size
        for (post, point) in zip(debugMarkers.children, points) {
            post.scale = [0.006 * size, height, 0.006 * size]
            post.position = SIMD3<Float>(georeference.map(point)) + [0, height / 2, 0]
        }
    }
}
