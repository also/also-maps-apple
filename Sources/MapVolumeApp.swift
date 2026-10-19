import SwiftUI

@main
struct MapVolumeApp: App {
    var body: some Scene {
        WindowGroup {
            MapVolumeView()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: MapVolumeModel.volumeSize.x,
                     height: MapVolumeModel.volumeSize.y,
                     depth: MapVolumeModel.volumeSize.z,
                     in: .meters)
    }
}
