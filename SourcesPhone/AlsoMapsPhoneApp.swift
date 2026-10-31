import SwiftUI

@main
struct AlsoMapsPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            PhoneMapView()
                .credentialGate()
                .appGate()
        }
    }
}
