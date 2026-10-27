import GameController
import RealityKit
import SwiftUI

struct MapVolumeView: View {
    static let windowID = "volume"

    @Environment(MapVolumeModel.self) private var model
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
            // Debug: MAPVOLUME_OPEN_TUNING=1 opens the Tuning window, and
            // MAPVOLUME_PRESENTATION=immersive (or volume) starts in that mode.
            if ProcessInfo.processInfo.environment["MAPVOLUME_OPEN_TUNING"] == "1" {
                openWindow(id: TuningView.windowID)
            }
            // MAPVOLUME_MARKERS=1 shows the debug markers, MAPVOLUME_TILE_BOUNDS=1
            // the tile bounds, and MAPVOLUME_STATE=<JSON from Copy View State>
            // restores that view.
            if ProcessInfo.processInfo.environment["MAPVOLUME_MARKERS"] == "1" {
                model.showsDebugMarkers = true
            }
            if ProcessInfo.processInfo.environment["MAPVOLUME_TILE_BOUNDS"] == "1" {
                model.showsTileBounds = true
            }
            // MAPVOLUME_FULL_IMMERSION=1 opens immersive modes with full immersion,
            // and MAPVOLUME_HUMAN_SCALE=1 keeps them at human scale.
            if ProcessInfo.processInfo.environment["MAPVOLUME_FULL_IMMERSION"] == "1" {
                model.fullImmersion = true
            }
            if ProcessInfo.processInfo.environment["MAPVOLUME_HUMAN_SCALE"] == "1" {
                model.humanScale = true
            }
            if let text = ProcessInfo.processInfo.environment["MAPVOLUME_STATE"] {
                do {
                    let state = try MapViewState.parse(text)
                    await Self.restore(state, model: model, open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
                } catch {
                    print("[MapVolume] MAPVOLUME_STATE not restored: \(error.localizedDescription)")
                }
            } else if let id = ProcessInfo.processInfo.environment["MAPVOLUME_PRESENTATION"],
               let presentation = MapPresentation.withID(id) {
                await present(presentation)
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
                        model: MapVolumeModel,
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
                        model: MapVolumeModel,
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
    func mapGestures(_ model: MapVolumeModel) -> some View {
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
    @Environment(MapVolumeModel.self) private var model

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
}
