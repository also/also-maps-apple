import SwiftUI

@main
struct AlsoMapsMacApp: App {
    private let view = StaticView.fromEnvironment()

    init() {
        // print() goes to a pipe or file when launched from a tool; make it
        // line-buffered so the log is live and survives being killed.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup {
            StaticMapView(view: view)
                .frame(width: view.viewportSize.width, height: view.viewportSize.height)
        }
        // Keep the selected preset's window size; the shared scene keeps
        // its LOD camera matched to the actual viewport.
        .windowResizability(.contentSize)
    }
}
