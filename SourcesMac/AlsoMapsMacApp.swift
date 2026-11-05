import SwiftUI

@main
struct AlsoMapsMacApp: App {
    private let view = StaticView.fromEnvironment(settings: .load())
    /// Edited in Settings and applied to every map window, which saves them.
    @State private var settings = StreamingSettings.load()

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
        }
        .defaultSize(width: view.viewportSize.width, height: view.viewportSize.height)

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

    init(start: StaticView, settings: StreamingSettings) {
        self.settings = settings
        _map = State(initialValue: ScreenMap(camera: start.cameraPose, settings: start.settings))
    }

    var body: some View {
        MetalOptionMapView(map: map)
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
                    TracesMenu(streaming: map.streaming) { map.go(to: $0) }
                    Menu("Places", systemImage: "mappin.and.ellipse") {
                        ForEach(PlaceLibrary.all) { place in
                            Button(place.name) { map.go(to: place) }
                        }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .padding(8)
            }
    }
}
