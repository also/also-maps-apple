import SwiftUI

// tvOS doesn't take place links.
#if !os(tvOS)
extension View {
    /// Goes to the place in an opened place link (PlaceLink), `alsomaps://`
    /// or a universal link, in this window rather than a new one. Links that
    /// aren't usable place links are ignored.
    func opensPlaceLinks(_ go: @escaping (Place) -> Void) -> some View {
        self
            .onOpenURL { url in
                if let place = PlaceLink.place(from: url) { go(place) }
            }
            // Universal links arrive through onOpenURL in SwiftUI, but take
            // the browsing activity too in case a platform delivers it that way.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL, let place = PlaceLink.place(from: url) { go(place) }
            }
            // Without this, the Mac opens a new window for every link.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}
#endif
