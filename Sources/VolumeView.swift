import GameController
import RealityKit
import SwiftUI

struct VolumeView: View {
    static let windowID = "volume"

    @Environment(MapModel.self) private var model
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
        .onAppear { model.volumeIsOpen = true }
        .onDisappear { model.volumeIsOpen = false }
        .ornament(attachmentAnchor: .scene(.bottomFront)) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
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
                    Button("Tuning", systemImage: "slider.horizontal.3") {
                        openWindow(id: TuningView.windowID)
                    }
                    .labelStyle(.iconOnly)
                    .help("Streaming settings")
                    if soundtrack.isAvailable {
                        Button(soundtrack.isMuted ? "Unmute Soundtrack" : "Mute Soundtrack",
                               systemImage: soundtrack.isMuted ? "speaker.slash" : "speaker.wave.2") {
                            soundtrack.isMuted.toggle()
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                if model.presentation.host == .volume {
                    AttributionView()
                }
            }
        }
        .task {
            // Debug: ALSOMAPS_OPEN_TUNING=1 opens the Tuning window, and
            // ALSOMAPS_PRESENTATION=immersive (or volume) starts in that mode.
            if ProcessInfo.processInfo.environment["ALSOMAPS_OPEN_TUNING"] == "1" {
                openWindow(id: TuningView.windowID)
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
        .padding(6)
        .glassBackgroundEffect()
    }

    private func present(_ presentation: MapPresentation) async {
        await Self.present(presentation, model: model,
                           open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
    }

    /// Switches presentation, opening or closing the immersive space as
    /// needed. Shared with the Tuning window's state restore.
    static func present(_ presentation: MapPresentation,
                        model: MapModel,
                        open: OpenImmersiveSpaceAction,
                        dismiss: DismissImmersiveSpaceAction) async {
        switch (model.presentation.host, presentation.host) {
        case (.volume, .immersive):
            guard case .opened = await open(id: ImmersiveMapView.spaceID) else { return }
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

extension View {
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

    var body: some View {
        VStack(spacing: 4) {
            if let message = model.streaming.statusMessage {
                Text(message).font(.callout)
            } else if model.streaming.loadProgress < 100 {
                ProgressView(value: Double(model.streaming.loadProgress), total: 100)
                    .frame(width: 200)
            }
            if model.tilesHeld {
                Text("Tiles held · view requests frozen")
                    .font(.caption)
            }
            if model.isRecordingTrack {
                Text("Recording track")
                    .font(.caption)
            }
            if model.isPlayingTrack {
                Text("Playing track · \(Self.minutes(model.playbackElapsed)) / \(Self.minutes(model.playbackDuration))")
                    .font(.caption)
                    .monospacedDigit()
            }
            if model.keyboardConnected {
                Text(MapInput.keyboardHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if model.controllerName != nil {
                Text(MapInput.controllerHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                Text(model.streaming.credits.map(\.text).filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
    }

    /// "m:ss".
    private static func minutes(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
