import SwiftUI

@main
struct MapVolumeApp: App {
    @State private var model = MapVolumeModel()
    @State private var soundtrack = Soundtrack()
    @Environment(\.scenePhase) private var scenePhase

    /// Read straight from the model, so a space opened right after the
    /// setting changes opens in the new style.
    private var immersionStyle: Binding<any ImmersionStyle> {
        Binding(get: { model.fullImmersion ? .full : .mixed },
                set: { model.fullImmersion = $0 is FullImmersionStyle })
    }

    var body: some Scene {
        WindowGroup(id: MapVolumeView.windowID) {
            MapVolumeView()
                .environment(model)
                .environment(soundtrack)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: MapVolumeModel.volumeSize.x,
                     height: MapVolumeModel.volumeSize.y,
                     depth: MapVolumeModel.volumeSize.z,
                     in: .meters)
        // Opening the app always brings back the map and its controls, even
        // if another window was the last one open.
        .defaultLaunchBehavior(.presented)
        .onChange(of: scenePhase, initial: true) { _, phase in
            soundtrack.setActive(phase == .active)
        }

        WindowGroup(id: TuningView.windowID) {
            TuningView()
                .environment(model)
        }
        .defaultSize(width: 520, height: 760)
        // A utility window: only opened on request, never restored at launch.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        ImmersiveSpace(id: ImmersiveMapView.spaceID) {
            ImmersiveMapView()
                .environment(model)
        }
        .immersionStyle(selection: immersionStyle, in: .mixed, .full)
        // In mixed immersion, keep the user's system environment (Mount Hood,
        // the Moon, …) around the immersive map instead of hiding it.
        .immersiveEnvironmentBehavior(.coexist)
    }
}
