import SwiftUI

@main
struct MapVolumeMacApp: App {
    init() {
        // print() goes to a pipe or file when launched from a tool; make it
        // line-buffered so the log is live and survives being killed.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup {
            MapWindowView()
        }
        // Square and fixed, so the real camera's field of view matches the
        // LOD camera's (60° both ways).
        .windowResizability(.contentSize)
    }
}
