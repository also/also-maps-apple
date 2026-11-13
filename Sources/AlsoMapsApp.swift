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
                .opensPlaceLinks { model.go(to: $0) }
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
        // Place links go to the volume, never open this.
        .handlesExternalEvents(matching: [])
        // A utility window: only opened on request, never restored at launch.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        ImmersiveSpace(id: ImmersiveMapView.realityKitSpaceID) {
            ImmersiveMapView()
                .environment(model)
                .appGate(presentsNotices: false)
        }
        .immersionStyle(selection: immersionStyle, in: .mixed, .full)
        // In mixed immersion, keep the user's system environment (Mount Hood,
        // the Moon, …) around the immersive map instead of hiding it.
        .immersiveEnvironmentBehavior(.coexist)

        // The same immersive presentation drawn with Metal, when Settings
        // says so (MapModel.drawsImmersiveWithMetal). Mixed or full, like
        // the RealityKit space; the renderer clears to transparent in mixed.
        // Not progressive: that needs the layered layout and a stencil mask
        // (notes/metal-renderer.md, "Immersion styles"). No `.coexist`: the
        // system doesn't draw its environment behind a CompositorLayer, so
        // bringing one in with the Digital Crown left a black sky
        // (notes/metal-renderer.md, "System environments").
        ImmersiveSpace(id: MetalImmersiveContent.spaceID) {
            MetalImmersiveContent(model: model)
        }
        .immersionStyle(selection: immersionStyle, in: .mixed, .full)
    }
}
