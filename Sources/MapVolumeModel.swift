import Foundation
import Observation
import RealityKit
import SwiftUI
import UIKit

/// Navigation and presentation for the map. The camera is the state
/// (`navigation`); each host shows it through the adaptive model, which
/// scales the world so the camera sits at the design eye point and what it
/// looks at sits on the table or floor. Tiles come from `streaming`. See
/// docs/camera-core.md.
@MainActor
@Observable
final class MapVolumeModel {
    /// Volume extents in metres (width, height, depth).
    nonisolated static let volumeSize = SIMD3<Double>(1.0, 0.6, 1.0)

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
            endManipulation()
            // Each host's level map has its own pitch; the assist re-targets.
            settlesPitch = pitchFollowsAltitude
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
    /// Whether the volume (map + controls) window is open. In a floor mode
    /// it can be closed while the immersive space stays up.
    var volumeIsOpen = false

    // MARK: Navigation state

    /// The camera, movement heading and heading link. The only stored
    /// navigation state.
    private(set) var navigation: NavigationState
    private var flight = ModelFlightStyle()
    /// The optional framing assist: pitch eases toward the level map up
    /// close and straight down far away (docs/camera-core.md §12.3).
    var pitchFollowsAltitude = true
    /// Lowest camera height above the estimated ground in room hosts.
    private static let minimumAltitude = 55.0

    // Ground estimates (docs/camera-core.md §8): the terrain height the view
    // ray meets (h_ray), the low envelope placed on the table or floor
    // (h_env), and the ground under the camera, for speed and limits.
    private var rayHeight = EasedHeight(0)
    private var envelopeHeight = EasedHeight(0)
    private var cameraGround = EasedHeight(0)
    /// Bumped per sample request so a slow, older result can't win.
    private var groundSampleGeneration = 0
    private var wasMoving = false
    /// Easing pitch to the new host's level map after a host switch.
    private var settlesPitch = false
    /// A place's framing assumes ground at 0 m until the first sample there;
    /// that sample moves the camera with the ground instead of rescaling.
    private var placeAwaitsGround = true

    /// The last valid adaptive-model framing, kept when the view ray misses.
    private var framing: AdaptiveModel.Framing?

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
    /// Index into PlaceLibrary.all of the last place jumped to, for cycling.
    private var currentPlaceIndex: Int?

    init() {
        let settings = StreamingSettings.load()
        self.settings = settings

        // Debug overrides: MAPVOLUME_LAT/_LON/_RADIUS/_HEADING pick the
        // starting view, and MAPVOLUME_TILESET_URL streams any 3D Tiles
        // tileset instead of Google's, no key needed.
        let env = ProcessInfo.processInfo.environment
        var place = Self.defaultPlace
        place.latitude = env["MAPVOLUME_LAT"].flatMap(Double.init) ?? place.latitude
        place.longitude = env["MAPVOLUME_LON"].flatMap(Double.init) ?? place.longitude
        place.radius = env["MAPVOLUME_RADIUS"].flatMap(Double.init) ?? place.radius
        place.heading = env["MAPVOLUME_HEADING"].flatMap(Double.init) ?? place.heading
        let camera = Self.framing(place, in: .volume, groundHeight: 0)
        navigation = ModelFlightStyle().activate(NavigationState(camera: camera))

        streaming = TileStreaming(inputs: StreamingInputs(anchor: StreamingAnchor(coordinate: place.coordinate)),
                                  settings: settings)
        placementRoot.addChild(root)
        root.addChild(debugMarkers)
        debugMarkers.isEnabled = false
        root.addChild(streaming.tilesRoot)
        streaming.tilesRoot.addChild(tileBoundsOverlay.root)
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

    /// The immersive space went away (dismissed by us or the system).
    func immersiveSpaceDidClose() {
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
    private func layOutGestureTarget() {
        let region = presentation.host == .immersive ? settings.immersiveRegion : 1
        let width = Float(2 * room.contentHalfWidth * region)
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

        // Debug: MAPVOLUME_PLACE=<id from Places.json> starts at that place.
        let env = ProcessInfo.processInfo.environment
        if let id = env["MAPVOLUME_PLACE"], let place = PlaceLibrary.all.first(where: { $0.id == id }) {
            go(to: place)
        }
    }

    // MARK: Places

    /// The camera that frames `place` in a host: its centre on the table or
    /// floor, `radius` metres of world across the host's half-width (half
    /// the volume, or the floor map's magnified equivalent), level.
    private static func framing(_ place: Place, in presentation: MapPresentation,
                                groundHeight: Double) -> CameraPose {
        guard case let .room(room) = presentation.geometry else {
            preconditionFailure("visionOS hosts are rooms")
        }
        return AdaptiveModel.framePlace(centre: place.coordinate, radius: place.radius,
                                        heading: place.heading * .pi / 180,
                                        room: room, groundHeight: groundHeight)
    }

    /// Jumps to `place`: a camera framing its position, size and facing.
    /// Tiles for the old area unload as they fall outside the streamed
    /// region; the new area streams in.
    func go(to place: Place) {
        if tilesHeld { setTilesHeld(false) }
        endManipulation()
        // Framed level for this host already.
        settlesPitch = false
        placeAwaitsGround = true
        currentPlaceIndex = PlaceLibrary.all.firstIndex(of: place)
        rayHeight.reset(to: 0)
        envelopeHeight.reset(to: 0)
        cameraGround.reset(to: 0)
        framing = nil
        var camera = Self.framing(place, in: presentation, groundHeight: 0)
        camera.height = context.clampHeight(camera.height)
        navigation = flight.activate(NavigationState(camera: camera))
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
        let room = self.room
        let levelPitch = room.levelPitch
        let startPitch = m.startPose.pitch
        let followsAltitude = pitchFollowsAltitude
        let target = AdaptiveModel.AnchorTarget(
            grab: m.grab,
            target: m.start + m.translation,
            scale: m.startScale * m.magnification,
            heading: m.startPose.heading + m.twist,
            headingOrigin: m.startPose.coordinate,
            pitch: { altitude in
                followsAltitude ? AdaptiveModel.pitchTarget(altitude: altitude, levelPitch: levelPitch) : startPitch
            })
        let solution = AdaptiveModel.solve(target, from: m.pose, room: room,
                                           rayHeight: rayHeight.value, envelopeHeight: effectiveEnvelope,
                                           context: context)
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
        guard streaming.isStreaming else { return }
        let dt = Double(deltaTime)
        applyInput(deltaTime: dt)
        if settlesPitch, manipulation == nil {
            // Until the pitch reaches the new host's target: a new scene's
            // first frames can have almost no time step, so a small step
            // doesn't mean it's done.
            navigation.camera = easedPitch(navigation.camera, deltaTime: dt)
            settlesPitch = abs(pitchTarget(for: navigation.camera) - navigation.camera.pitch) > 1e-4
            #if DEBUG
            if !settlesPitch {
                print("[MapVolume] pitch settled at \(String(format: "%.2f", navigation.camera.pitch * 180 / .pi))° for \(presentation.id)")
            }
            #endif
        }
        updateGround(deltaTime: dt)
        applyView()
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
            print("[MapVolume] game controller: \(controller ?? "none")")
            #endif
        }

        let input = MapInput.current()

        // Buttons act once, on the frame they go down.
        for action in input.held.subtracting(heldActions) {
            perform(action)
        }
        heldActions = input.held

        guard input.isMoving else {
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

    /// Model flight, then the framing assists: pitch follows altitude (if
    /// on) about the georeference point, within the horizon limit.
    private func steer(with input: ControlInput, deltaTime: Double) {
        flight.dollySurfaceHeight = rayHeight.value
        // Turning, climbing and zooming first, limited (while held) by how
        // much of the held region they'd show; then travel, limited by how
        // far it goes from it.
        var looking = input
        looking.move = .zero
        var state = flight.step(navigation, input: looking, deltaTime: deltaTime, context: context)
        if pitchFollowsAltitude, input.climb != 0 || input.dolly != 0 {
            state.camera = easedPitch(state.camera, deltaTime: deltaTime)
        }
        state.camera.pitch = min(state.camera.pitch, pitchLimit(for: state.camera))
        if withinHeldLimits(state, checking: [.size]) { navigation = state }

        guard input.move != .zero else { return }
        var moving = ControlInput()
        moving.move = input.move
        moving.fast = input.fast
        state = flight.step(navigation, input: moving, deltaTime: deltaTime, context: context)
        state.camera.pitch = min(state.camera.pitch, pitchLimit(for: state.camera))
        if withinHeldLimits(state, checking: [.travel]) { navigation = state }
    }

    /// The pitch policy's step: toward θ_target for the altitude, swinging
    /// the camera about the georeference point so what's on the table stays.
    private func pitchTarget(for camera: CameraPose) -> Double {
        min(AdaptiveModel.pitchTarget(altitude: camera.height - cameraGround.value, levelPitch: room.levelPitch),
            pitchLimit(for: camera))
    }

    private func easedPitch(_ camera: CameraPose, deltaTime: Double) -> CameraPose {
        let target = pitchTarget(for: camera)
        guard abs(target - camera.pitch) > 1e-6 else { return camera }
        let pitch = camera.pitch + (target - camera.pitch) * min(1, deltaTime * 6)
        guard let current = AdaptiveModel.framing(camera: camera, room: room, rayHeight: rayHeight.value,
                                                  envelopeHeight: effectiveEnvelope)
        else { return camera }
        var turned = camera
        turned.pitch = pitch
        let forward = turned.basis.forward
        var swung = CameraPose(position: current.georeferencePoint - forward * current.range,
                               forward: forward, fallbackHeading: camera.heading)
        swung.height = context.clampHeight(swung.height)
        return swung
    }

    private func pitchLimit(for camera: CameraPose) -> Double {
        AdaptiveModel.pitchLimit(cameraHeight: camera.height, rayHeight: rayHeight.value, latitude: camera.latitude)
    }

    private func perform(_ action: MapInput.Action) {
        let places = PlaceLibrary.all
        switch action {
        case .nextPlace where !places.isEmpty:
            let index = ((currentPlaceIndex ?? -1) + 1) % places.count
            go(to: places[index])
        case .previousPlace where !places.isEmpty:
            let index = ((currentPlaceIndex ?? 0) - 1 + places.count) % places.count
            go(to: places[index])
        case .faceNorth:
            navigation = NavigationOperations.faceNorth(navigation)
        case .toggleFly:
            setTilesHeld(!tilesHeld)
        default:
            break
        }
    }

    // MARK: Limits

    private var context: NavigationContext {
        NavigationContext(cameraGround: cameraGround.value,
                          minimumAltitude: Self.minimumAltitude,
                          maximumAltitude: settings.zoomOutLimitKilometres * 1_100)
    }

    private enum HeldLimit { case travel, size }

    /// While tiles are held: travel keeps the georeference point within
    /// 1.5 × the held region of its centre, and climbing or zooming keeps the
    /// shown region within 3 × its size. A step that would break a checked
    /// limit, and make it worse, is refused, so you slide to a stop.
    private func withinHeldLimits(_ state: NavigationState,
                                  checking limits: Set<HeldLimit> = [.travel, .size]) -> Bool {
        guard tilesHeld, let held = heldInputs,
              let candidate = AdaptiveModel.framing(camera: state.camera, room: room,
                                                    rayHeight: rayHeight.value, envelopeHeight: effectiveEnvelope)
        else { return true }
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

    /// The envelope used for placement, never above the ray surface.
    private var effectiveEnvelope: Double { min(envelopeHeight.value, rayHeight.value) }

    /// The ground under the camera, every frame, from loaded tiles detailed
    /// enough to trust: coarse tiles' lowest vertices can be kilometres
    /// below the real ground. It sets speed and limits only; it never moves
    /// the view.
    ///
    /// The georeference ground (where the map sits on the table or floor)
    /// comes only from the 3×3 surface sample once motion settles, plus the
    /// Earth's curve far out. Reading it from the loaded tiles continuously
    /// fed back on itself: a new height rescaled the map, which moved the LOD
    /// camera, which changed the tiles, which changed the height. Nothing
    /// changes it while tiles are held or during a gesture.

    private func updateGround(deltaTime: Double) {
        let camera = navigation.camera
        let altitude = max(camera.height - cameraGround.value, 0)
        let detailed = streaming.renderedHeightRanges().filter { $0.radius <= max(2 * altitude, 500) }
        if let ground = GroundEstimates.envelope(detailed, around: camera.coordinate,
                                                 radius: max(20, 0.05 * altitude), statistic: .minimum) {
            cameraGround.aim(at: min(max(ground, -500), 9_000))
        }
        cameraGround.ease(deltaTime: deltaTime, halfLife95: 0.3)

        guard !tilesHeld, manipulation == nil, let framing else { return }
        let shown = framing.shownRadius(room)
        if shown >= Self.curvatureAnchorRadius {
            // Far out the Earth's curve, not the terrain, decides: sea level
            // at the view's edges meets the floor. Smooth in the camera, so
            // it follows continuously.
            envelopeHeight.aim(at: rayHeight.value - GroundEstimates.curvatureDrop(shown),
                               hysteresis: 0.002 * shown)
        }
        rayHeight.ease(deltaTime: deltaTime)
        envelopeHeight.ease(deltaTime: deltaTime)
    }

    /// Above this half-width the Earth's curve, not the terrain, decides
    /// where the ground sits: the edges fall away by ~200 m at 50 km.
    private static let curvatureAnchorRadius = 50_000.0

    /// Where the map sits: the lowest of a 3×3 sample across the shown region
    /// once motion settles (live only; it may load tiles), for both the
    /// surface the view ray meets and the ground placed on the table or
    /// floor. A failed sample keeps the last estimate.
    private func requestGroundSample() {
        guard !tilesHeld, let framing else { return }
        let shown = framing.shownRadius(room)
        guard shown < Self.curvatureAnchorRadius else { return }
        groundSampleGeneration += 1
        let generation = groundSampleGeneration
        let centre = Geodesy.geodetic(framing.georeferencePoint).coordinate
        streaming.sampleGroundHeight(around: centre, radius: shown) { [weak self] height in
            MainActor.assumeIsolated {
                guard let self, generation == self.groundSampleGeneration, !self.tilesHeld else { return }
                guard height.isFinite else { return }
                let ground = min(max(height, -500), 9_000)
                #if DEBUG
                print("[MapVolume] ground sample \(Int(ground)) m (was \(Int(self.envelopeHeight.value)) m)")
                #endif
                if self.placeAwaitsGround {
                    // Places are framed relative to the ground.
                    self.placeAwaitsGround = false
                    self.navigation.camera.height += ground - self.rayHeight.value
                    self.rayHeight.reset(to: ground)
                    self.envelopeHeight.reset(to: ground)
                } else {
                    self.rayHeight.aim(at: ground)
                    self.envelopeHeight.aim(at: ground)
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
        guard case let .room(room) = presentation.geometry else {
            preconditionFailure("visionOS hosts are rooms")
        }
        return room
    }

    /// Places everything from the camera: the georeference, the tiles root
    /// relative to whichever anchor is streaming, the gesture slab and, while
    /// live, the streaming inputs. Called every frame.
    private func applyView() {
        guard streaming.isStreaming else { return }
        let room = self.room
        let camera = navigation.camera
        if let current = AdaptiveModel.framing(camera: camera, room: room, rayHeight: rayHeight.value,
                                               envelopeHeight: effectiveEnvelope) {
            framing = current
        } else if framing == nil {
            framing = AdaptiveModel.nadirFraming(camera: camera, room: room, rayHeight: rayHeight.value,
                                                 envelopeHeight: effectiveEnvelope)
        } else {
            #if DEBUG
            print("[MapVolume] view ray missed the surface (pitch \(camera.pitch * 180 / .pi)°); keeping the last framing")
            #endif
        }
        guard let framing else { return }

        if !tilesHeld {
            streaming.inputs = streamingInputs(for: framing)
        }
        let georeference = framing.georeference
        streaming.tilesRoot.transform = Transform(georeference.placement(of: streaming.inputs.anchor))

        // The slab lies on the ground at the placement point, level with the
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
        let room = self.room
        let camera = navigation.camera
        let policy: AOIPolicy = presentation.host == .immersive
            ? .blended(reachPerAltitude: 3, regionMultiplier: settings.immersiveRegion)
            : .georeference(regionMultiplier: 1)
        let viewer = Geodesy.geodetic(framing.georeference.ecef(map: room.designEye)).coordinate
        let area = policy.area(viewerNadir: viewer,
                               altitude: max(camera.height - cameraGround.value, 0),
                               heading: camera.heading,
                               georeferencePoint: Geodesy.geodetic(framing.georeferencePoint).coordinate,
                               shownRadius: framing.shownRadius(room))
        let anchor = StreamingAnchor(coordinate: area.centre, height: effectiveEnvelope)
        return StreamingInputs(anchor: anchor,
                               lod: AdaptiveModel.lodCamera(framing: framing, eye: room.designEye, anchor: anchor),
                               regionHeading: area.heading,
                               streamingRadius: area.radius)
    }

    // MARK: View state

    func captureState() -> MapViewState {
        MapViewState(navigation: navigation,
                     rayHeight: rayHeight.value,
                     envelopeHeight: envelopeHeight.value,
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
        endManipulation()
        settings = state.settings
        groundSampleGeneration += 1  // Drop any sample in flight.
        placeAwaitsGround = false
        rayHeight.reset(to: state.groundEstimate.ray)
        envelopeHeight.reset(to: state.groundEstimate.envelope)
        roomPlacement = state.roomPlacement.placement
        var navigation = state.navigationState
        navigation.camera.pitch = min(navigation.camera.pitch, pitchLimit(for: navigation.camera))
        self.navigation = navigation
        framing = nil
        if let held = state.heldStreaming {
            streaming.inputs = held
            heldInputs = held
            tilesHeld = true
        }
        applyView()
        #if DEBUG
        print("[MapVolume] restored view state: \(captureState().json())")
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
