import SwiftUI

@main
struct AlsoMapsApp: App {
    @State private var model = MapModel()
    @State private var soundtrack = Soundtrack()
    @Environment(\.scenePhase) private var scenePhase

    private var isBlocked: Bool { AppConfigStore.shared.blocking != nil }

    /// Read straight from the model, so a space opened right after the
    /// setting changes opens in the new style.
    private var immersionStyle: Binding<any ImmersionStyle> {
        Binding(get: { model.fullImmersion ? .full : .mixed },
                set: { model.fullImmersion = $0 is FullImmersionStyle })
    }

    var body: some Scene {
        WindowGroup(id: VolumeView.windowID) {
            VolumeView()
                .environment(model)
                .environment(soundtrack)
                .credentialGate()
                .appGate()
                .keepsVolumeDepth()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: MapModel.volumeSize.x,
                     height: MapModel.volumeSize.y,
                     depth: MapModel.volumeSize.z,
                     in: .meters)
        // Opening the app always brings back the map and its controls, even
        // if another window was the last one open.
        .defaultLaunchBehavior(.presented)
        .onChange(of: scenePhase, initial: true) { _, phase in
            soundtrack.setActive(phase == .active && !isBlocked)
            if phase != .active { model.flushTrack() }
        }
        .onChange(of: isBlocked) { _, blocked in
            soundtrack.setActive(scenePhase == .active && !blocked)
            if blocked { model.flushTrack() }
        }

        WindowGroup(id: SettingsView.windowID) {
            @Bindable var model = model
            SettingsView(settings: $model.settings)
                .environment(model)
                .appGate(presentsNotices: false)
        }
        .defaultSize(width: 760, height: 760)
        // A utility window: only opened on request, never restored at launch.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        ImmersiveSpace(id: ImmersiveMapView.spaceID) {
            ImmersiveMapView()
                .environment(model)
                .appGate(presentsNotices: false)
        }
        .immersionStyle(selection: immersionStyle, in: .mixed, .full)
        // In mixed immersion, keep the user's system environment (Mount Hood,
        // the Moon, …) around the immersive map instead of hiding it.
        .immersiveEnvironmentBehavior(.coexist)
    }
}
