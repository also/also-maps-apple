import SwiftUI

@main
struct MapVolumeMacApp: App {
    var body: some Scene {
        WindowGroup {
            MapWindowView()
        }
        .defaultSize(width: 1100, height: 750)
    }
}

/// The macOS map window. A placeholder for now: the map itself (a RealityView
/// with a perspective camera, driven by the shared navigation model) comes
/// later.
struct MapWindowView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "map")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Map Volume")
                .font(.title)
            Text("macOS port in progress")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
