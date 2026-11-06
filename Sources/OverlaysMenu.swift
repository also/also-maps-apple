#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

/// What's draped over the map: GPS traces from a GeoJSON file, and a dot
/// where each photo in the library was taken. Opens and removes each. Hosts
/// say how to go to where they are.
struct OverlaysMenu: View {
    let streaming: TileStreaming
    let go: (Place) -> Void

    @State private var showsImporter = false

    /// `.geojson` has no system type, and exports are often just `.json`.
    private static let fileTypes = [UTType(filenameExtension: "geojson"), .json].compactMap { $0 }

    private var isLoading: Bool { streaming.isLoadingTraces || streaming.isLoadingPhotos }

    var body: some View {
        Menu("Overlays", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath") {
            Section("Traces") {
                Button("Open Traces…", systemImage: "folder") { showsImporter = true }
                if let name = streaming.tracesName {
                    Button("Remove \(name)", systemImage: "trash", role: .destructive) {
                        streaming.removeTraces()
                    }
                }
            }
            Section("Photos") {
                if let points = streaming.photoPoints {
                    Button("Go to Photos", systemImage: "photo.on.rectangle") {
                        go(points.place(name: "Photos"))
                    }
                    Button("Hide \(points.photoCount) Photos", systemImage: "eye.slash") {
                        streaming.hidePhotos()
                    }
                } else {
                    Button("Show Photo Locations", systemImage: "photo.on.rectangle") {
                        Task {
                            if let place = await streaming.showPhotos() { go(place) }
                        }
                    }
                }
            }
        }
        .disabled(isLoading)
        .help(streaming.isLoadingPhotos ? "Reading photo locations"
              : streaming.isLoadingTraces ? "Loading traces"
              : "Show GPS traces from a GeoJSON file, or where your photos were taken")
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
        .alert("Couldn't Show Photos",
               isPresented: Binding(get: { streaming.photosError != nil },
                                    set: { if !$0 { streaming.photosError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(streaming.photosError ?? "")
        }
    }
}
#endif
