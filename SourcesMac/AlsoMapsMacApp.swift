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
            // Starts at the selected preset's camera, then flies.
            ScreenMapView(start: view)
                .frame(minWidth: 400, minHeight: 300)
        }
        .defaultSize(width: view.viewportSize.width, height: view.viewportSize.height)
    }
}
