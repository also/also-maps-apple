#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

/// The Traces list, like the Places panel: GPS files the user has loaded and
/// their camera recordings, each shown or hidden on the map, with any track
/// ready to play. Tapping one goes to it. Files are opened here and removed
/// from their row's menu; recordings stay, and can be shared.
struct TracesPanel: View {
    let library: TraceLibrary
    let tracks: TrackSession
    let go: (Place) -> Void
    /// The host's own start, which also resets its gestures and framing.
    let play: (Track) -> Void

    @State private var showsImporter = false

    /// `.geojson` and `.kml` have no system types, and GeoJSON exports are
    /// often just `.json`.
    private static let fileTypes = [UTType(filenameExtension: "geojson"), .json,
                                    UTType(filenameExtension: "kml")].compactMap { $0 }

    var body: some View {
        VStack(spacing: 0) {
            if library.entries.isEmpty {
                ContentUnavailableView("No Traces", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
                                       description: Text("Open a GeoJSON or KML file, or record a track."))
                    .frame(maxHeight: .infinity)
            } else {
                List(library.entries) { entry in
                    TraceRow(entry: entry, library: library, tracks: tracks, go: go, play: play)
                }
            }
            HStack {
                Button("Open…", systemImage: "folder") { showsImporter = true }
                    .help("Open a GeoJSON or KML file")
                    .disabled(library.isLoading)
                if library.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .padding()
        }
        #if !os(iOS)
        .frame(width: 360, height: 440)
        #endif
        .onAppear { library.refreshRecordings() }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: Self.fileTypes) { result in
            switch result {
            case .success(let url):
                Task {
                    if let place = await library.open(url) { go(place) }
                }
            case .failure(let error):
                library.error = error.localizedDescription
            }
        }
        .alert("Couldn't Open Traces",
               isPresented: Binding(get: { library.error != nil },
                                    set: { if !$0 { library.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.error ?? "")
        }
    }
}

private struct TraceRow: View {
    let entry: TraceEntry
    let library: TraceLibrary
    let tracks: TrackSession
    let go: (Place) -> Void
    let play: (Track) -> Void

    private var isRecording: Bool { entry.id == tracks.recordingID }
    private var isFile: Bool {
        if case .file = entry.source { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(isRecording ? .red : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.hasTrack {
                Button("Play", systemImage: "play.fill") {
                    if let track = library.track(entry.id) { play(track) }
                }
                .labelStyle(.iconOnly)
                .help("Fly along \(entry.name)")
                .disabled(tracks.isPlaying || tracks.isRecording)
            }
            Button(entry.isShown ? "Hide" : "Show", systemImage: entry.isShown ? "eye" : "eye.slash") {
                library.setShown(entry.id, !entry.isShown)
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(entry.isShown ? .primary : .secondary)
            .help(entry.isShown ? "Hide on the map" : "Show on the map")
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
        .onTapGesture {
            if let place = entry.place { go(place) }
        }
        .contextMenu {
            if let place = entry.place {
                Button("Go There", systemImage: "location") { go(place) }
            }
            if let url = library.recordingURL(entry), !isRecording {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            if isFile {
                Button("Remove", systemImage: "trash", role: .destructive) { library.remove(entry.id) }
            }
        }
        .swipeActions {
            if isFile {
                Button("Remove", systemImage: "trash", role: .destructive) { library.remove(entry.id) }
            }
        }
    }

    private var icon: String {
        if isRecording { return "record.circle" }
        if case .recording = entry.source { return "video" }
        return entry.hasTrack ? "point.topleft.down.to.point.bottomright.curvepath"
            : "point.bottomleft.forward.to.point.topright.scurvepath"
    }

    private var detail: String {
        switch entry.source {
        case .recording:
            return isRecording ? "Recording now" : "Camera recording"
        case .file(let fileExtension):
            let kind = switch (entry.hasTrack, entry.hasLines) {
            case (true, true): "Track and lines"
            case (true, false): "Track"
            default: "Lines"
            }
            return "\(kind) · \(fileExtension.uppercased())"
        }
    }
}
#endif
