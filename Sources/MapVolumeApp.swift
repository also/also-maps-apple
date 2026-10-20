import SwiftUI

@main
struct MapVolumeApp: App {
    @State private var model = MapVolumeModel()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup(id: MapVolumeView.windowID) {
            MapVolumeView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: MapVolumeModel.volumeSize.x,
                     height: MapVolumeModel.volumeSize.y,
                     depth: MapVolumeModel.volumeSize.z,
                     in: .meters)
        // Opening the app always brings back the map and its controls, even
        // if another window was the last one open.
        .defaultLaunchBehavior(.presented)

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
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
