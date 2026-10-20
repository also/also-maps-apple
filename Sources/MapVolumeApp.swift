import SwiftUI

@main
struct MapVolumeApp: App {
    @State private var model = MapVolumeModel()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup(id: "volume") {
            MapVolumeView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: MapVolumeModel.volumeSize.x,
                     height: MapVolumeModel.volumeSize.y,
                     depth: MapVolumeModel.volumeSize.z,
                     in: .meters)

        WindowGroup(id: TuningView.windowID) {
            TuningView()
                .environment(model)
        }
        .defaultSize(width: 520, height: 760)

        ImmersiveSpace(id: ImmersiveMapView.spaceID) {
            ImmersiveMapView()
                .environment(model)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
