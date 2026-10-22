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
        .receivesGameControllerInput()
        .onAppear { model.volumeIsOpen = true }
        .onDisappear { model.volumeIsOpen = false }
        .ornament(attachmentAnchor: .scene(.bottomFront)) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    presentationPicker
                    Toggle(isOn: Binding(get: { model.isFlying },
                                         set: { model.setFlying($0) })) {
                        Label("Fly", systemImage: "airplane")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .help("Fly through the loaded map (streaming frozen)")
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
            // MAPVOLUME_PRESENTATION=floor5x (etc.) starts in that mode.
            if ProcessInfo.processInfo.environment["MAPVOLUME_OPEN_TUNING"] == "1" {
                openWindow(id: TuningView.windowID)
            }
            if let id = ProcessInfo.processInfo.environment["MAPVOLUME_PRESENTATION"],
               let presentation = MapPresentation.all.first(where: { $0.id == id }) {
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
        switch (model.presentation.host, presentation.host) {
        case (.volume, .immersive):
            guard case .opened = await openImmersiveSpace(id: ImmersiveMapView.spaceID) else { return }
        case (.immersive, .volume):
            await dismissImmersiveSpace()
        default:
            break
        }
        model.presentation = presentation
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
                    .onChanged { value in model.magnify(by: value.magnification) }
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
            if let message = model.statusMessage {
                Text(message).font(.callout)
            } else if model.loadProgress < 100 {
                ProgressView(value: Double(model.loadProgress), total: 100)
                    .frame(width: 200)
            }
            if model.isFlying {
                Text("Flying · map frozen")
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
                Image("GoogleMapsLogo")
                    .accessibilityLabel("Google Maps")
                Text(model.credits.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
    }
}
