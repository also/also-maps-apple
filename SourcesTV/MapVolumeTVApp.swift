import SwiftUI

@main
struct MapVolumeTVApp: App {
    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup {
            MapWindowView()
                .ignoresSafeArea()
        }
    }
}
