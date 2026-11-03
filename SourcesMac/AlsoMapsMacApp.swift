import SwiftUI

@main
struct AlsoMapsMacApp: App {
    private let view = StaticView.fromEnvironment(settings: .load())
    /// Edited in Settings and applied to every map window, which saves them.
    @State private var settings = StreamingSettings.load()
    @State private var headset = HeadsetSession()

    init() {
        // print() goes to a pipe or file when launched from a tool; make it
        // line-buffered so the log is live and survives being killed.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup {
            // Starts at the selected preset's camera, then flies.
            MacMapView(start: view, settings: settings)
                .frame(minWidth: 400, minHeight: 300)
                .credentialGate()
                .appGate()
                .environment(headset)
        }
        .defaultSize(width: view.viewportSize.width, height: view.viewportSize.height)

        RemoteImmersiveSpace(id: HeadsetSession.spaceID) {
            HeadsetContent(session: headset)
        }
        // No passthrough: the project's immersive mode is full immersion.
        .immersionStyle(selection: .constant(.full), in: .full)

        Settings {
            SettingsView(settings: $settings)
                .frame(width: 680, height: 520)
        }
    }
}

/// The flying map with a Places menu. The mouse and trackpad go through
/// PointerSurface. Keys are read from the keyboard device each frame
/// (MapInput); the view takes them only so the system doesn't beep at
/// unhandled keys.
struct MacMapView: View {
    let settings: StreamingSettings
    @State private var map: ScreenMap
    @FocusState private var focused: Bool
    @Environment(HeadsetSession.self) private var headset
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    init(start: StaticView, settings: StreamingSettings) {
        self.settings = settings
        _map = State(initialValue: ScreenMap(camera: start.cameraPose, settings: start.settings))
    }

    var body: some View {
        ScreenMapView(map: map)
            // Over the map, under the controls, the same size as the scene.
            .overlay {
                PointerSurface(map: map)
                    .ignoresSafeArea()
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .all) { _ in .handled }
            .onAppear { focused = true }
            .onChange(of: settings) { _, settings in map.settings = settings }
            .overlay(alignment: .topTrailing) {
                HStack {
                    headsetButton
                    Menu("Places", systemImage: "mappin.and.ellipse") {
                        ForEach(PlaceLibrary.all) { place in
                            Button(place.name) { map.go(to: place) }
                        }
                    }
                    .menuStyle(.button)
                }
                .fixedSize()
                .padding(8)
            }
    }

    /// Shows this window's map on a Vision Pro, or brings it back.
    @ViewBuilder private var headsetButton: some View {
        if headset.isOpen, headset.map === map {
            // 1:1 instead of scaled to the room: the camera's real height.
            Toggle("Human Scale", systemImage: "figure.stand",
                   isOn: Binding(get: { map.headsetHumanScale }, set: { map.headsetHumanScale = $0 }))
                .toggleStyle(.button)
            Button("Back to Mac", systemImage: "macwindow") {
                Task { await dismissImmersiveSpace() }
            }
        } else {
            Button("View in Vision Pro", systemImage: "visionpro") {
                headset.map = map
                Task {
                    let result = await openImmersiveSpace(id: HeadsetSession.spaceID)
                    print("Headset: open immersive space: \(result)")
                    switch result {
                    case .opened: break
                    default: headset.map = nil
                    }
                }
            }
            .disabled(headset.isOpen)
        }
    }
}
