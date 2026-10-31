#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

/// Opens a GeoJSON file of traces to drape over the map, and takes it away
/// again. Hosts say how to go to where the traces are.
struct TracesMenu: View {
    let streaming: TileStreaming
    let go: (Place) -> Void

    @State private var showsImporter = false

    /// `.geojson` has no system type, and exports are often just `.json`.
    private static let fileTypes = [UTType(filenameExtension: "geojson"), .json].compactMap { $0 }

    var body: some View {
        Menu("Traces", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath") {
            Button("Open Traces…", systemImage: "folder") { showsImporter = true }
            if let name = streaming.tracesName {
                Button("Remove \(name)", systemImage: "trash", role: .destructive) {
                    streaming.removeTraces()
                }
            }
        }
        .disabled(streaming.isLoadingTraces)
        .help(streaming.isLoadingTraces ? "Loading traces" : "Show GPS traces from a GeoJSON file")
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: Self.fileTypes) { result in
            switch result {
            case .success(let url):
                Task {
                    if let place = await streaming.openTraces(url) { go(place) }
                }
            case .failure(let error):
                streaming.tracesError = error.localizedDescription
            }
        }
        .alert("Couldn't Open Traces",
               isPresented: Binding(get: { streaming.tracesError != nil },
                                    set: { if !$0 { streaming.tracesError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(streaming.tracesError ?? "")
        }
    }
}
#endif
