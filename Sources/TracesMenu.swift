#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

/// Opens a file of GPS traces and takes it away again. GeoJSON is draped
/// over the map; so are a KML file's lines on the ground, while its lines in
/// the air become a track to draw as a tube and fly along. Hosts say how to
/// go to what was opened.
struct TracesMenu: View {
    let streaming: TileStreaming
    let tracks: TrackSession
    let go: (Place) -> Void

    @State private var showsImporter = false
    /// The debug file is opened once, however often the menu appears.
    @MainActor private static var openedFromEnvironment = false

    /// `.geojson` and `.kml` have no system types, and GeoJSON exports are
    /// often just `.json`.
    private static let fileTypes = [UTType(filenameExtension: "geojson"), .json,
                                    UTType(filenameExtension: "kml")].compactMap { $0 }

    var body: some View {
        Menu("Traces", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath") {
            Button("Open Traces…", systemImage: "folder") { showsImporter = true }
            if let name = streaming.tracesName {
                Button("Remove \(name)", systemImage: "trash", role: .destructive) {
                    streaming.removeTraces()
                }
            }
            if let track = tracks.openedTrack {
                Button("Close \(track.name) Track", systemImage: "xmark") {
                    tracks.closeOpenedTrack()
                }
            }
        }
        .disabled(streaming.isLoadingTraces)
        .help(streaming.isLoadingTraces ? "Loading traces" : "Show GPS traces from a GeoJSON or KML file")
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: Self.fileTypes) { result in
            switch result {
            case .success(let url):
                Task {
                    if let place = await open(url) { go(place) }
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
        .task {
            // Debug: ALSOMAPS_TRACES=<path to GeoJSON or KML> opens it as if
            // picked, without moving the camera.
            guard !Self.openedFromEnvironment,
                  let path = ProcessInfo.processInfo.environment["ALSOMAPS_TRACES"], !path.isEmpty else { return }
            Self.openedFromEnvironment = true
            _ = await open(URL(fileURLWithPath: path))
        }
    }

    /// Opens a file and returns where to go: a track's start, or else the
    /// draped lines. Nil, with `tracesError` set, if it couldn't be opened.
    private func open(_ url: URL) async -> Place? {
        guard url.pathExtension.lowercased() == "kml" else { return await streaming.openTraces(url) }
        let name = url.deletingPathExtension().lastPathComponent
        let kml: KMLFile
        do {
            kml = try await Task.detached(priority: .userInitiated) {
                try KMLFile(data: TileStreaming.read(url))
            }.value
        } catch {
            streaming.tracesError = error.localizedDescription
            return nil
        }
        let ground = kml.groundLines
        var place: Place?
        if !ground.isEmpty {
            place = await streaming.openTraces(named: name) { try TraceFile(lines: ground, name: $0) }
        }
        if let track = kml.track(name: name) {
            tracks.open(track)
            place = track.start
        }
        return place
    }
}
#endif
