import Foundation
import Observation

/// An imported route for one map, on any platform but tvOS: reading a GPX
/// or GeoJSON file, draping it on the map's surface, drawing it coloured by
/// value (RouteOverlay), and replaying it with a chase camera. The map
/// feeds it the frame time and, while a replay runs, takes the camera from
/// it, as it does from TrackSession.
///
/// Surface heights for draping are sampled from the tiles while the app
/// runs and kept only in memory: Google's terms don't allow storing or
/// exporting them (README, "Google Maps Platform terms").
@MainActor
@Observable
final class RouteSession {
    /// The route open, if any.
    private(set) var route: ImportedRoute?
    /// Why the last file didn't open, for showing.
    private(set) var errorMessage: String?

    var colouring = RouteColouring.speed {
        didSet { if colouring != oldValue { rebuild() } }
    }
    var heightMode = RouteHeightMode.ground {
        didSet {
            guard heightMode != oldValue else { return }
            if !needsDrape {
                drapeProgress = 1
            } else if !drapeIndices.isEmpty {
                drapeProgress = Double(nextDrape) / Double(drapeIndices.count)
            }
            rebuild()
        }
    }
    /// The colours' values, for the legend; nil for a single colour.
    private(set) var scale: RouteColourScale?
    /// How much of the surface has been sampled, 0–1 (1 when nothing needs it).
    private(set) var drapeProgress = 1.0

    /// Route seconds a second.
    var speedup = 30.0
    static let speedups: [Double] = [10, 30, 60, 120]
    private(set) var isReplaying = false
    /// Whole seconds of the route's replay clock played and in all, for
    /// status lines (observed, so they change once a second).
    private(set) var replayElapsed = 0
    private(set) var replayDuration = 0
    @ObservationIgnored private(set) var replayTime: TimeInterval = 0

    /// The tube; its root goes in the map's scene.
    @ObservationIgnored let overlay = RouteOverlay()

    /// Asks the map's streamer for the surface height at each point (see
    /// TileStreaming.sampleSurfaceHeights); false if it can't yet. Set by
    /// the host.
    @ObservationIgnored var sampleSurfaceHeights: (([GeoCoordinate], @escaping @Sendable ([Double]) -> Void) -> Bool)?

    // Draping: the points sampled, what came back, and the batch in flight.
    @ObservationIgnored private var drapeIndices: [Int] = []
    @ObservationIgnored private var drapeHeights: [Double?] = []
    @ObservationIgnored private var nextDrape = 0
    @ObservationIgnored private var drapeInFlight: (id: Int, start: Int, sent: Date)?
    @ObservationIgnored private var drapeRequests = 0

    @ObservationIgnored private var heights: [Double] = []
    @ObservationIgnored private var playback: TrackPlayback?
    @ObservationIgnored private var chase = ChaseCamera(distance: 100, height: 40)
    /// Metres either side of the moving point the travel heading is taken over.
    @ObservationIgnored private var lookahead = 20.0

    /// Points sampled per request: the tube fills in as each batch lands.
    static let drapeBatchSize = 64
    /// A batch that hasn't come back in this long is sent again (a tile
    /// source switch replaces the streamer, which drops it).
    static let drapeTimeout: TimeInterval = 45

    // MARK: Opening

    /// Reads a route file (the file importer may hand over a security-scoped
    /// URL) and draws it. Returns the place that frames it, or nil, with
    /// `errorMessage` set, if it couldn't be read.
    func open(_ url: URL) -> Place? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return fail("The route file couldn't be opened: \(error.localizedDescription)", url)
        }
        let document: RouteDocument
        switch RouteImport.document(from: data, fileExtension: url.pathExtension) {
        case let .success(read): document = read
        case let .failure(error): return fail(error.localizedDescription, url)
        }
        guard let route = ImportedRoute(document: document,
                                        fallbackName: url.deletingPathExtension().lastPathComponent)
        else { return fail(RouteImportError.empty.localizedDescription, url) }
        load(route)
        print("[AlsoMaps] route \(url.lastPathComponent): \(route.points.count) points in \(route.segments.count) segments, \(Int(route.length)) m, \(Int(route.replayDuration)) s\(route.hasTimes ? "" : " (no times)")")
        return route.place
    }

    private func fail(_ message: String, _ url: URL) -> Place? {
        errorMessage = message
        print("[AlsoMaps] route \(url.lastPathComponent) not opened: \(message)")
        return nil
    }

    func load(_ route: ImportedRoute) {
        stopReplay()
        self.route = route
        errorMessage = nil
        drapeRequests += 1  // Drops any batch in flight.
        drapeInFlight = nil
        nextDrape = 0
        drapeIndices = route.drapeIndices(maximumCount: Self.environmentDrapeSamples ?? 400)
        drapeHeights = Array(repeating: nil, count: drapeIndices.count)
        drapeProgress = needsDrape ? 0 : 1
        chase = ChaseCamera(typicalSpeed: route.typicalSpeed)
        Self.applyChaseOverrides(&chase)
        lookahead = min(max(5 * route.typicalSpeed, 15), 1_000)
        overlay.isEnabled = true
        // The first colouring this route has values for, unless it has the
        // one already chosen.
        if !colouring.isAvailable(for: route) {
            let fallback = [RouteColouring.speed, .heartRate, .elevation, .cadence]
                .first { $0.isAvailable(for: route) } ?? .plain
            colouring = fallback  // Rebuilds.
        } else {
            rebuild()
        }
    }

    func close() {
        stopReplay()
        route = nil
        scale = nil
        errorMessage = nil
        drapeRequests += 1
        drapeInFlight = nil
        drapeIndices = []
        drapeHeights = []
        heights = []
        drapeProgress = 1
        overlay.geometry = nil
        overlay.isEnabled = false
    }

    // MARK: Frame loop

    /// Asks for the next batch of surface heights if one's due, and advances
    /// a replay; returns the chase camera while one runs.
    func update(deltaTime: Double) -> CameraPose? {
        requestDrapeIfDue()
        return advanceReplay(deltaTime: deltaTime)
    }

    // MARK: Draping

    /// On the ground always; as recorded only where the file has no height.
    private var needsDrape: Bool {
        guard let route else { return false }
        return heightMode == .ground || route.points.contains { $0.recordedHeight == nil }
    }

    private func requestDrapeIfDue() {
        guard let route, needsDrape, let sample = sampleSurfaceHeights else { return }
        if let inFlight = drapeInFlight {
            guard Date().timeIntervalSince(inFlight.sent) > Self.drapeTimeout else { return }
            nextDrape = inFlight.start
            drapeInFlight = nil
        }
        guard nextDrape < drapeIndices.count else { return }
        let range = nextDrape..<min(nextDrape + Self.drapeBatchSize, drapeIndices.count)
        let coordinates = range.map { route.points[drapeIndices[$0]].coordinate }
        drapeRequests += 1
        let id = drapeRequests
        let asked = sample(coordinates) { [weak self] heights in
            MainActor.assumeIsolated {
                self?.receiveDrape(heights, range: range, id: id)
            }
        }
        guard asked else { return }  // No streamer yet; try again next frame.
        drapeInFlight = (id, range.lowerBound, Date())
        nextDrape = range.upperBound
    }

    private func receiveDrape(_ heights: [Double], range: Range<Int>, id: Int) {
        guard drapeInFlight?.id == id else { return }
        drapeInFlight = nil
        for (k, height) in zip(range, heights) where height.isFinite {
            drapeHeights[k] = min(max(height, -500), 9_000)
        }
        drapeProgress = drapeIndices.isEmpty ? 1 : Double(range.upperBound) / Double(drapeIndices.count)
        #if DEBUG
        let hits = heights.filter(\.isFinite).count
        print("[AlsoMaps] route surface: \(hits) of \(heights.count) samples, \(Int(drapeProgress * 100))% done")
        #endif
        rebuild()
    }

    /// Heights, colours and the tube from what's known now.
    private func rebuild() {
        guard let route else { return }
        let surface = route.surfaceHeights(indices: drapeIndices, heights: drapeHeights)
        heights = route.heights(mode: heightMode, surface: surface)
        let values = colouring.values(route)
        scale = colouring == .plain ? nil : RouteColourScale(values: values, minimumSpan: colouring.minimumSpan)
        overlay.geometry = RouteGeometry(route: route, positions: route.positions(heights: heights),
                                         values: values, scale: scale, liftsByRadius: heightMode == .ground)
        // A replay keeps its time on the new heights.
        if isReplaying { playback = route.playback(heights: heights) }
    }

    // MARK: Replay

    /// Starts the replay from the beginning and returns the first chase
    /// camera, or nil if there's no route.
    func startReplay() -> CameraPose? {
        guard let route, !isReplaying, let playback = route.playback(heights: heights) else { return nil }
        self.playback = playback
        isReplaying = true
        replayTime = 0
        replayElapsed = 0
        replayDuration = Int(route.replayDuration.rounded(.up))
        chase.reset()
        print("[AlsoMaps] replaying route \(route.name) at \(Int(speedup))×, chasing \(Int(chase.distance)) m back")
        return chasePose(deltaTime: 0)
    }

    func stopReplay() {
        guard isReplaying else { return }
        isReplaying = false
        playback = nil
        overlay.markerPosition = nil
        #if DEBUG
        print("[AlsoMaps] route replay stopped at \(Int(replayTime)) s")
        #endif
    }

    private func advanceReplay(deltaTime: Double) -> CameraPose? {
        guard isReplaying, let route else { return nil }
        replayTime = min(replayTime + deltaTime * speedup, route.replayDuration)
        let elapsed = Int(replayTime)
        if replayElapsed != elapsed { replayElapsed = elapsed }
        let pose = chasePose(deltaTime: deltaTime)
        // Stops by itself at the end, leaving the camera there.
        if replayTime >= route.replayDuration { stopReplay() }
        return pose
    }

    private func chasePose(deltaTime: Double) -> CameraPose? {
        guard let route, let playback else { return nil }
        let point = playback.pose(at: replayTime)
        overlay.markerPosition = point.position
        return chase.pose(following: point.coordinate, height: point.height,
                          travelHeading: route.travelHeading(atReplayTime: replayTime, lookahead: lookahead),
                          deltaTime: deltaTime)
    }

    // MARK: Launch options

    /// ALSOMAPS_ROUTE=<path to a .gpx or .geojson file> opens it at launch;
    /// a relative path is in the app's Documents folder (which the Files
    /// app shows on visionOS and iPhone). Then:
    /// - ALSOMAPS_ROUTE_COLOUR=speed|elevation|heartRate|cadence|plain
    /// - ALSOMAPS_ROUTE_HEIGHT=ground|recorded
    /// - ALSOMAPS_ROUTE_REPLAY=<speed-up, e.g. 30> starts the replay.
    /// - ALSOMAPS_ROUTE_DRAPE_SAMPLES=<n> samples the surface at up to n
    ///   points (400 by default).
    /// - ALSOMAPS_CHASE_DISTANCE=<metres> chases that far back (and 0.4×
    ///   that above); ALSOMAPS_CHASE_TURNS=0 keeps the heading fixed.
    struct LaunchOptions {
        var url: URL
        var colouring: RouteColouring?
        var heightMode: RouteHeightMode?
        var replaySpeedup: Double?
    }

    static var launchOptions: LaunchOptions? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ALSOMAPS_ROUTE"], !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL.documentsDirectory.appendingPathComponent(expanded)
        return LaunchOptions(url: url,
                             colouring: env["ALSOMAPS_ROUTE_COLOUR"].flatMap(RouteColouring.init(rawValue:)),
                             heightMode: env["ALSOMAPS_ROUTE_HEIGHT"].flatMap(RouteHeightMode.init(rawValue:)),
                             replaySpeedup: env["ALSOMAPS_ROUTE_REPLAY"].flatMap(Double.init))
    }

    /// Opens the launch route, if any, with its options; returns its place.
    func openFromEnvironment() -> Place? {
        guard let options = Self.launchOptions else { return nil }
        if let colouring = options.colouring { self.colouring = colouring }
        if let heightMode = options.heightMode { self.heightMode = heightMode }
        if let speedup = options.replaySpeedup, speedup > 0 { self.speedup = speedup }
        return open(options.url)
    }

    /// Whether the launch options ask for a replay.
    static var replaysAtLaunch: Bool { launchOptions?.replaySpeedup.map { $0 > 0 } ?? false }

    private static var environmentDrapeSamples: Int? {
        ProcessInfo.processInfo.environment["ALSOMAPS_ROUTE_DRAPE_SAMPLES"].flatMap(Int.init).map { max($0, 2) }
    }

    private static func applyChaseOverrides(_ chase: inout ChaseCamera) {
        let env = ProcessInfo.processInfo.environment
        if let distance = env["ALSOMAPS_CHASE_DISTANCE"].flatMap(Double.init), distance > 0 {
            chase.distance = distance
            chase.height = 0.4 * distance
        }
        if env["ALSOMAPS_CHASE_TURNS"] == "0" { chase.turnsWithTravel = false }
    }
}
