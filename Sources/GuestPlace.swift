import Foundation
import Observation
import RealityKit

/// A second ("guest") place streamed and shown with the map, to compare two
/// places at the same scale: beside the map's centre or over it (see
/// GuestPlacement). It has its own TileStreaming around its own centre,
/// from the same tile source and key, so it's a second root tileset request
/// (for Google, a second map session) and roughly doubles tiles, memory and
/// requests while it's shown.
///
/// The host (MapModel on visionOS, ScreenMap on a screen) owns it: it adds
/// `streaming.tilesRoot` to its map frame, calls `apply` wherever it places
/// its own tiles, and `update` once a frame after its own streaming update.
/// Held tiles (Fly) hold the guest's too: its inputs stay as they were while
/// its tiles keep following the map.
@MainActor
@Observable
final class GuestPlace {
    let place: Place
    let streaming: TileStreaming
    private(set) var placement: GuestPlacement

    var mode: GuestMode { placement.mode }

    /// RealityKit draws an overlaid guest at this opacity so the host shows
    /// through; the Metal renderer uses it for its translucent pass.
    static let overlayOpacity: Float = 0.6

    /// Whether to draw it: an overlay waits for both ground samples.
    var isShown: Bool { placement.isPlaced }

    /// Ground samples asked for and not yet answered, and how many have
    /// failed, so a place with no surface to hit stops asking.
    @ObservationIgnored private var hostSampleInFlight = false
    @ObservationIgnored private var guestSampleInFlight = false
    @ObservationIgnored private var failedSamples = 0
    /// Bumped when the host's centre moves, so a sample from before can't win.
    @ObservationIgnored private var sampleGeneration = 0
    private static let maximumFailedSamples = 6

    init(place: Place, mode: GuestMode, heading: Double = 0, radius: Double? = nil,
         hostCentre: GeoCoordinate, hostRadius: Double, settings: StreamingSettings,
         customTileHandler: CNTileLoadHandler?) {
        self.place = place
        placement = GuestPlacement(mode: mode, hostCentre: hostCentre, hostRadius: max(hostRadius, 50),
                                   guestCentre: place.coordinate, guestRadius: max(radius ?? place.radius, 50),
                                   heading: heading)
        streaming = TileStreaming(inputs: StreamingInputs(anchor: placement.guestAnchor,
                                                          streamingRadius: placement.guestRadius),
                                  settings: settings, label: "guest \(place.id)")
        streaming.customTileHandler = customTileHandler
        applyMode()
    }

    // MARK: Changes

    /// Where the host's centre is now (going to another place moves it): the
    /// guest follows, and an overlay samples the host's ground there again.
    func rehost(centre: GeoCoordinate, radius: Double) {
        placement.hostCentre = centre
        placement.hostRadius = max(radius, 50)
        placement.hostGround = nil
        hostSampleInFlight = false
        failedSamples = 0
        sampleGeneration += 1
    }

    func setMode(_ mode: GuestMode) {
        guard mode != placement.mode else { return }
        placement.mode = mode
        failedSamples = 0
        applyMode()
    }

    /// Turns the guest about its centre, radians clockwise seen from above.
    func turn(by angle: Double) {
        placement.heading = remainder(placement.heading + angle, 2 * .pi)
    }

    private func applyMode() {
        // RealityKit's way to see the host through an overlaid guest. UNVERIFIED:
        // how RealityKit sorts large translucent photogrammetry meshes; some
        // of the guest may hide other parts of itself, or draw over the host
        // where it's behind it (notes/two-places.md).
        if placement.mode == .overlay {
            streaming.tilesRoot.components.set(OpacityComponent(opacity: Self.overlayOpacity))
        } else {
            streaming.tilesRoot.components.remove(OpacityComponent.self)
        }
    }

    // MARK: Frame

    /// Places the guest's tiles in the host's map frame from the host's
    /// georeference, and (unless held) carries the host's LOD camera across.
    func apply(georeference: Georeference, hostInputs: StreamingInputs, held: Bool) {
        let stream = placement.stream
        if !held {
            streaming.inputs = stream.inputs(hostLOD: hostInputs.lod, hostAnchor: hostInputs.anchor)
        }
        streaming.tilesRoot.transform = Transform(stream.placement(in: georeference))
        streaming.tilesRoot.isEnabled = isShown
    }

    /// One selection and load pass, after the host's. `host` answers the
    /// overlay's ground sample at the host's centre.
    func update(deltaTime: Float, host: TileStreaming, held: Bool) {
        if !held { requestMissingGround(host: host) }
        streaming.update(deltaTime: deltaTime)
    }

    /// An overlay matches the two grounds. Each is sampled once, when it's
    /// missing and the streamer to ask is running; neither is ever saved.
    private func requestMissingGround(host: TileStreaming) {
        guard placement.mode == .overlay, failedSamples < Self.maximumFailedSamples else { return }
        let radius = GuestPlacement.groundSampleRadius(guestRadius: placement.guestRadius)
        let generation = sampleGeneration
        if placement.hostGround == nil, !hostSampleInFlight, host.isStreaming {
            hostSampleInFlight = true
            host.sampleGroundHeight(around: placement.hostCentre, radius: radius) { [weak self] height in
                MainActor.assumeIsolated {
                    guard let self, generation == self.sampleGeneration else { return }
                    self.hostSampleInFlight = false
                    self.placement.hostGround = self.sampled(height, what: "host")
                }
            }
        }
        if placement.guestGround == nil, !guestSampleInFlight, streaming.isStreaming {
            guestSampleInFlight = true
            streaming.sampleGroundHeight(around: placement.guestCentre, radius: radius) { [weak self] height in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.guestSampleInFlight = false
                    self.placement.guestGround = self.sampled(height, what: "guest")
                }
            }
        }
    }

    /// A sampled height, clamped as the host's are; nil (asked again next
    /// frame) if the sample hit nothing. After repeated misses, sea level.
    private func sampled(_ height: Double, what: String) -> Double? {
        guard height.isFinite else {
            failedSamples += 1
            #if DEBUG
            print("[AlsoMaps] guest \(place.id): \(what) ground sample missed (\(failedSamples))")
            #endif
            return failedSamples >= Self.maximumFailedSamples ? 0 : nil
        }
        let ground = min(max(height, -500), 9_000)
        #if DEBUG
        print("[AlsoMaps] guest \(place.id): \(what) ground \(Int(ground)) m")
        #endif
        return ground
    }

    // MARK: Starting

    /// Starts its streamer (and asks for its key, like the host's). Call
    /// once the host is streaming.
    func start() {
        streaming.start()
    }

    /// The guest ALSOMAPS_GUEST_PLACE asks for, for testing:
    /// ALSOMAPS_GUEST_PLACE=<place id>, with ALSOMAPS_GUEST_MODE=side|overlay
    /// (side by default), ALSOMAPS_GUEST_HEADING (degrees clockwise from
    /// north) and ALSOMAPS_GUEST_RADIUS (metres; the place's own by default).
    static func environmentRequest()
        -> (place: Place, mode: GuestMode, heading: Double, radius: Double?)? {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["ALSOMAPS_GUEST_PLACE"], !id.isEmpty else { return nil }
        guard let place = PlaceLibrary.all.first(where: { $0.id == id }) else {
            print("[AlsoMaps] ALSOMAPS_GUEST_PLACE: no place \(id)")
            return nil
        }
        let mode = env["ALSOMAPS_GUEST_MODE"].flatMap(GuestMode.init(environmentValue:)) ?? .sideBySide
        let heading = (env["ALSOMAPS_GUEST_HEADING"].flatMap(Double.init) ?? 0) * .pi / 180
        return (place, mode, heading, env["ALSOMAPS_GUEST_RADIUS"].flatMap(Double.init))
    }
}

extension TileStreaming.Credit {
    /// Every streamer's credits, each once, in order: the map's, then a guest's.
    @MainActor static func merged(_ streams: [TileStreaming]) -> [TileStreaming.Credit] {
        var seen = Set<TileStreaming.Credit>()
        return streams.flatMap(\.credits).filter { seen.insert($0).inserted }
    }
}
