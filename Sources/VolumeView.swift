import GameController
import RealityKit
import SwiftUI

struct VolumeView: View {
    static let windowID = "volume"

    @Environment(MapModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Soundtrack.self) private var soundtrack
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RealityView { content in
            model.attach(content, host: .volume)
        }
        .mapGestures(model)
        // visionOS turns controller input into look-and-pinch events by
        // default; route it to the Game Controller framework for MapInput.
        .handlesGameControllerEvents(matching: .gamepad)
        // With the map in an immersive space the volume is only the control
        // panel; its baseplate would outline an empty box.
        .volumeBaseplateVisibility(model.presentation.host == .volume ? .automatic : .hidden)
        .onAppear { model.volumeIsOpen = true }
        .onDisappear { model.volumeDidClose() }
        // Closing the window doesn't make it disappear, it sends its scene
        // to the background; coming back (Show Controls) makes it active.
        .onChange(of: scenePhase) { _, phase in
            model.volumeIsOpen = phase != .background
            // The Metal space has no Show Controls panel, so closing the
            // volume leaves Immersive too.
            if phase == .background, model.metalImmersiveIsOpen {
                Task { await dismissImmersiveSpace() }
            }
        }
        // The controls as the system's bottom toolbar, which visionOS
        // places clear of the window bar and close button.
        .toolbar {
            ToolbarItemGroup(placement: .bottomOrnament) {
                presentationPicker
                Toggle(isOn: Binding(get: { model.tilesHeld },
                                     set: { model.setTilesHeld($0) })) {
                    Label("Fly", systemImage: "airplane")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Hold tiles: fly through what's loaded without requesting more")
                Toggle(isOn: Binding(get: { model.isRecordingTrack },
                                     set: { $0 ? model.startTrack() : model.stopTrack() })) {
                    Label(model.isRecordingTrack ? "Stop Recording" : "Record Track",
                          systemImage: model.isRecordingTrack ? "stop.circle.fill" : "record.circle")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Record the camera's track to a file in Files")
                .disabled(model.isPlayingTrack)
                Toggle(isOn: Binding(get: { model.showsTrack }, set: { model.showsTrack = $0 })) {
                    Label(model.showsTrack ? "Hide Track" : "Show Track",
                          systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Draw the track being recorded, or the latest one")
                Toggle(isOn: Binding(get: { model.isPlayingTrack },
                                     set: { $0 ? model.startPlayback() : model.stopPlayback() })) {
                    Label(model.isPlayingTrack ? "Stop Playback" : "Play Track",
                          systemImage: model.isPlayingTrack ? "stop.fill" : "play.fill")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Fly the latest track in real time")
                .disabled(model.isRecordingTrack || model.latestTrack == nil)
                if let track = model.latestTrack {
                    ShareLink(item: track) {
                        Label("Share Track", systemImage: "square.and.arrow.up")
                    }
                    .labelStyle(.iconOnly)
                    .help("Share \(track.deletingPathExtension().lastPathComponent)")
                }
                Menu("Places", systemImage: "mappin.and.ellipse") {
                    ForEach(PlaceLibrary.all) { place in
                        Button(place.name) { model.go(to: place) }
                    }
                }
                .labelStyle(.iconOnly)
                .help("Go to a place")
                Button("Settings", systemImage: "gearshape") {
                    openWindow(id: SettingsView.windowID)
                }
                .labelStyle(.iconOnly)
                .help("Settings")
                if soundtrack.isAvailable {
                    Button(soundtrack.isMuted ? "Unmute Soundtrack" : "Mute Soundtrack",
                           systemImage: soundtrack.isMuted ? "speaker.slash" : "speaker.wave.2") {
                        soundtrack.isMuted.toggle()
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        // The attribution on a back edge of the volume, away from the window
        // controls below its front, which the system keeps a readable size
        // as the window moves away (so a gap under the toolbar can't clear
        // them): above the map in volume mode, and at the back of the empty
        // volume in the Metal immersive space. The RealityKit immersive space
        // shows its own.
        .ornament(attachmentAnchor: .scene(model.presentation.host == .volume ? .topBack : .bottomBack),
                  contentAlignment: .bottom) {
            if model.presentation.host == .volume || model.metalImmersiveIsOpen {
                AttributionView()
            }
        }
        .task {
            // Debug: ALSOMAPS_OPEN_SETTINGS=1 opens the Settings window, and
            // ALSOMAPS_PRESENTATION=immersive (or volume) starts in that mode.
            if ProcessInfo.processInfo.environment["ALSOMAPS_OPEN_SETTINGS"] == "1" {
                openWindow(id: SettingsView.windowID)
            }
            // ALSOMAPS_MARKERS=1 shows the debug markers, ALSOMAPS_TILE_BOUNDS=1
            // the tile bounds, and ALSOMAPS_STATE=<JSON from Copy View State>
            // restores that view.
            if ProcessInfo.processInfo.environment["ALSOMAPS_MARKERS"] == "1" {
                model.showsDebugMarkers = true
            }
            if ProcessInfo.processInfo.environment["ALSOMAPS_TILE_BOUNDS"] == "1" {
                model.showsTileBounds = true
            }
            // ALSOMAPS_SHOW_TRACK=1 draws the latest track.
            if ProcessInfo.processInfo.environment["ALSOMAPS_SHOW_TRACK"] == "1" {
                model.showsTrack = true
            }
            // ALSOMAPS_FULL_IMMERSION=1 opens immersive modes with full immersion,
            // and ALSOMAPS_HUMAN_SCALE=1 keeps them at human scale.
            if ProcessInfo.processInfo.environment["ALSOMAPS_FULL_IMMERSION"] == "1" {
                model.fullImmersion = true
            }
            if ProcessInfo.processInfo.environment["ALSOMAPS_HUMAN_SCALE"] == "1" {
                model.humanScale = true
            }
            if let text = ProcessInfo.processInfo.environment["ALSOMAPS_STATE"] {
                do {
                    let state = try MapViewState.parse(text)
                    await Self.restore(state, model: model, open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
                } catch {
                    print("[AlsoMaps] ALSOMAPS_STATE not restored: \(error.localizedDescription)")
                }
            } else if let id = ProcessInfo.processInfo.environment["ALSOMAPS_PRESENTATION"],
               let presentation = MapPresentation.withID(id) {
                await present(presentation)
            }
            // ALSOMAPS_PLAY_TRACK=1 plays the latest track (after any of the above).
            if ProcessInfo.processInfo.environment["ALSOMAPS_PLAY_TRACK"] == "1" {
                model.startPlayback()
            }
        }
    }

    private var presentationPicker: some View {
        Picker("View", selection: Binding(
            get: { model.presentation },
            set: { presentation in Task { await present(presentation) } }
        )) {
            ForEach(MapPresentation.all) { presentation in
                Text(presentation.name).tag(presentation)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 420)
    }

    private func present(_ presentation: MapPresentation) async {
        await Self.present(presentation, model: model,
                           open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
    }

    /// Switches presentation, opening or closing the immersive space as
    /// needed. Shared with the Settings window's state restore.
    static func present(_ presentation: MapPresentation,
                        model: MapModel,
                        open: OpenImmersiveSpaceAction,
                        dismiss: DismissImmersiveSpaceAction) async {
        switch (model.presentation.host, presentation.host) {
        case (.volume, .immersive):
            guard case .opened = await open(id: ImmersiveMapView.spaceID(for: model)) else { return }
        case (.immersive, .volume):
            await dismiss()
        default:
            break
        }
        model.presentation = presentation
    }

    /// Switches to a captured state's presentation, then restores the rest.
    static func restore(_ state: MapViewState,
                        model: MapModel,
                        open: OpenImmersiveSpaceAction,
                        dismiss: DismissImmersiveSpaceAction) async {
        if let presentation = MapPresentation.withID(state.host) {
            await present(presentation, model: model, open: open, dismiss: dismiss)
        }
        model.restore(state)
    }
}

/// Holds the volume at its depth. A window's depth follows its content, so a
/// flat screen standing in for the map (the first-run choice, a blocking
/// notice) would otherwise leave the map in a shallow volume when it returns.
private struct VolumeDepth: ViewModifier {
    @PhysicalMetric(from: .meters) private var depth = MapModel.volumeSize.z

    func body(content: Content) -> some View {
        content.frame(depth: depth, alignment: .front)
    }
}

extension View {
    func keepsVolumeDepth() -> some View {
        modifier(VolumeDepth())
    }

    /// Drag to pan, two-handed pinch to zoom and twist to turn, on the model's
    /// gesture target, in whichever scene is showing the map.
    func mapGestures(_ model: MapModel) -> some View {
        self
            .gesture(
                // Default minimum distance, so a pinch has to actually move
                // before it pans.
                DragGesture()
                    .targetedToEntity(model.gestureTarget)
                    .onChanged { value in
                        let start = value.convert(value.startLocation3D, from: .local, to: .scene)
                        let now = value.convert(value.location3D, from: .local, to: .scene)
                        model.drag(from: start, to: now)
                    }
                    .onEnded { _ in model.endDrag() }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .targetedToEntity(model.gestureTarget)
                    .onChanged { value in
                        let start = value.convert(value.startLocation3D, from: .local, to: .scene)
                        model.magnify(by: value.magnification, startedAt: start)
                    }
                    .onEnded { _ in model.endMagnify() }
            )
            .simultaneousGesture(
                // Two-handed twist about the vertical; runs alongside zoom so
                // one motion can turn and scale at once.
                RotateGesture3D(constrainedToAxis: .y)
                    .targetedToEntity(model.gestureTarget)
                    .onChanged { value in
                        let rotation = value.convert(value.rotation, from: .local, to: .scene)
                        let start = value.convert(value.startLocation3D, from: .local, to: .scene)
                        model.rotate(by: rotation, startedAt: start)
                    }
                    .onEnded { _ in model.endRotate() }
            )
    }
}

/// Google's terms require the Google Maps logo and the data attribution for
/// the tiles on screen to be visible alongside them. The logo is Google's
/// white variant (for dark backgrounds, like this glass), unaltered at its
/// native size.
struct AttributionView: View {
    @Environment(MapModel.self) private var model
    @AppStorage(ViewPreferences.showsStatsKey) private var showsStats = false

    /// The attribution, how loading is going, why nothing loads (a missing
    /// or refused key), and the stats if Settings shows them. No hints.
    var body: some View {
        VStack(spacing: 4) {
            if let message = model.streaming.statusMessage {
                Text(message).font(.callout)
            } else if model.streaming.loadProgress < 100 {
                ProgressView(value: Double(model.streaming.loadProgress), total: 100)
                    .frame(width: 200)
            }
            if showsStats {
                let stats = model.streaming.stats
                VStack(spacing: 2) {
                    Text("\(stats.renderedTiles) tiles · \(stats.entities) entities · \(Int(model.streaming.loadProgress))%")
                    Text(stats.requestsSummary)
                    if model.airTraffic.feed.isRunning {
                        Text(model.airTraffic.feed.summary)
                    }
                }
                .font(.caption.monospacedDigit())
            }
            HStack(spacing: 8) {
                if model.streaming.showsGoogleLogo {
                    Image("GoogleMapsLogo")
                        .accessibilityLabel("Google Maps")
                }
                // Providers' own logos (e.g. Cesium ion) come in their credits.
                ForEach(model.streaming.credits.compactMap(\.imageURL), id: \.self) { url in
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(height: 18)
                }
                // Live air traffic's source, after the tiles' own.
                let airTraffic = model.airTraffic.feed.isRunning ? [AirTrafficQuery.attribution] : []
                Text((model.streaming.credits.map(\.text) + airTraffic).filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
    }
}
