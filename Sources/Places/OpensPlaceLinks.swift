import SwiftUI

// tvOS doesn't take place links or files.
#if !os(tvOS)
extension View {
    /// Goes to the place in an opened place link (PlaceLink), `alsomaps://`
    /// or a universal link, in this window rather than a new one. Links that
    /// aren't usable place links are ignored.
    ///
    /// An opened file is imported into PlaceStore, replacing the imported
    /// set, and `imported` runs; a file that can't be imported shows an
    /// alert.
    func opensPlaces(go: @escaping (Place) -> Void,
                     imported: @escaping () -> Void = {}) -> some View {
        modifier(OpensPlaces(go: go, imported: imported))
    }
}

private struct OpensPlaces: ViewModifier {
    var go: (Place) -> Void
    var imported: () -> Void
    @State private var problem: PlaceStore.ImportError?

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                if url.isFileURL {
                    do throws(PlaceStore.ImportError) {
                        try PlaceStore.shared.importFile(url)
                        imported()
                    } catch {
                        problem = error
                    }
                } else if let place = PlaceLink.place(from: url) {
                    go(place)
                }
            }
            // Universal links arrive through onOpenURL in SwiftUI, but take
            // the browsing activity too in case a platform delivers it that way.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL, let place = PlaceLink.place(from: url) { go(place) }
            }
            // Without this, the Mac opens a new window for every link.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .alert("Couldn't Open the File", isPresented: Binding(get: { problem != nil },
                                                                 set: { if !$0 { problem = nil } }),
                   presenting: problem) { _ in
                Button("OK") {}
            } message: { problem in
                Text(problem.localizedDescription)
            }
    }
}
#endif
