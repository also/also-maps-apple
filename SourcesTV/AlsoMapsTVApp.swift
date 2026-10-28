import SwiftUI

@main
struct AlsoMapsTVApp: App {
    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup {
            TVMapView()
        }
    }
}
