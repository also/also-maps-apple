import Foundation
import Observation

/// The Traces list for one map: the files the user has loaded and their
/// camera recordings (TraceStore), each shown or hidden. Shown lines are
/// draped over the tiles together (TileStreaming); shown tracks are drawn
/// as tubes (TrackSession), and any track can be played.
@MainActor
@Observable
final class TraceLibrary {
    /// Loaded files are copied here.
    static let directory = URL.applicationSupportDirectory.appending(path: "Traces")

    private(set) var entries: [TraceEntry]
    private(set) var isLoading = false
    /// Why the last file couldn't be opened or drawn, until it's been read.
    var error: String?
    /// The entry ALSOMAPS_TRACES opened, once it's open.
    private(set) var environmentEntryID: String?

    @ObservationIgnored private var store: TraceStore
    @ObservationIgnored private let streaming: TileStreaming
    @ObservationIgnored private let tracks: TrackSession
    /// Tracks read from their files, by entry ID.
    @ObservationIgnored private var loadedTracks: [String: Track] = [:]
    /// Bumped by each change to the shown lines, so a slower earlier join
    /// can't replace a later one.
    @ObservationIgnored private var linesGeneration = 0

    init(streaming: TileStreaming, tracks: TrackSession) {
        self.streaming = streaming
        self.tracks = tracks
        store = TraceStore(directory: Self.directory, recordingsDirectory: TrackSession.directory)
        store.syncRecordings()
        entries = store.entries
        tracks.recordingsChanged = { [weak self] in self?.refreshRecordings() }
        streaming.tracesFailed = { [weak self] message in self?.error = message }
        // Joined lines from the last launch; applyLines writes them anew.
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("shown-") {
            try? FileManager.default.removeItem(at: file)
        }
        applyLines()
        applyTracks()
        // Debug: ALSOMAPS_TRACES=<path to GeoJSON or KML> opens it as if
        // picked, without moving the camera.
        if let path = ProcessInfo.processInfo.environment["ALSOMAPS_TRACES"], !path.isEmpty {
            Task {
                _ = await open(URL(fileURLWithPath: path))
                environmentEntryID = entries.first?.id
            }
        }
    }

    // MARK: Changing the list

    /// Loads a GeoJSON or KML file the user picked, shown, and returns where
    /// to go to see it; nil, with `error` set, if it couldn't be read.
    func open(_ url: URL) async -> Place? {
        isLoading = true
        defer { isLoading = false }
        let name = url.deletingPathExtension().lastPathComponent
        let directory = store.directory
        do {
            let entry = try await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return try TraceStore.prepare(Data(contentsOf: url), fileExtension: url.pathExtension,
                                              name: name, in: directory)
            }.value
            store.insert(entry)
            entries = store.entries
            if entry.hasLines { applyLines() }
            if entry.hasTrack { applyTracks() }
            return entry.place
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func setShown(_ id: String, _ isShown: Bool) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        store.setShown(id: id, isShown)
        entries = store.entries
        if entry.hasLines { applyLines() }
        if entry.hasTrack { applyTracks() }
    }

    /// Unloads a file. Recordings stay: they're the user's files.
    func remove(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }), case .file = entry.source else { return }
        store.remove(id: id)
        entries = store.entries
        loadedTracks[id] = nil
        if entry.hasLines { applyLines() }
        if entry.hasTrack { applyTracks() }
    }

    /// Picks up recordings started, finished or deleted since.
    func refreshRecordings() {
        if store.syncRecordings() { entries = store.entries }
        // A finished recording that's shown is now drawn from its file.
        applyTracks()
    }

    // MARK: Tracks

    /// An entry's track, read once from its file. Nil for the recording in
    /// progress, which isn't finished yet.
    func track(_ id: String) -> Track? {
        if let track = loadedTracks[id] { return track }
        guard id != tracks.recordingID, let entry = entries.first(where: { $0.id == id }) else { return nil }
        do {
            let track = try store.track(of: entry)
            loadedTracks[id] = track
            return track
        } catch {
            self.error = "Couldn't read \(entry.name): \(error.localizedDescription)"
            return nil
        }
    }

    /// The recording's file, for sharing.
    func recordingURL(_ entry: TraceEntry) -> URL? {
        guard case .recording = entry.source else { return nil }
        return store.url(of: entry)
    }

    // MARK: Drawing

    /// Drapes the shown entries' lines, joined off the main thread.
    private func applyLines() {
        linesGeneration += 1
        let generation = linesGeneration
        let store = store
        Task {
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                guard let collection = store.linesCollection() else { return nil }
                // A new name each time: cesium-native may still be reading
                // the last one.
                let url = store.directory.appending(path: "shown-\(UUID().uuidString).geojson")
                do {
                    try collection.write(to: url, options: .atomic)
                    return url
                } catch {
                    print("[AlsoMaps] couldn't write the shown traces: \(error)")
                    return nil
                }
            }.value
            guard generation == linesGeneration else {
                if let url { try? FileManager.default.removeItem(at: url) }
                return
            }
            let previous = streaming.tracesURL
            streaming.showTraces(at: url)
            if let previous, previous != url { try? FileManager.default.removeItem(at: previous) }
        }
    }

    /// Draws the shown entries' tracks.
    private func applyTracks() {
        let shown = entries.filter { $0.isShown && $0.hasTrack }
        var shownTracks: [String: Track] = [:]
        for entry in shown {
            if let track = track(entry.id) { shownTracks[entry.id] = track }
        }
        tracks.show(shownTracks, shownIDs: Set(shown.map(\.id)))
    }
}
