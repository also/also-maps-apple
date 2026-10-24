import SwiftUI

@main
struct MapVolumeMacApp: App {
    var body: some Scene {
        WindowGroup {
            MapWindowView()
        }
        // Square and fixed, so the real camera's field of view matches the
        // LOD camera's (60° both ways).
        .windowResizability(.contentSize)
    }
}
