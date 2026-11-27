import Foundation

/// One entry in the Traces list: a file the user loaded, or one of their
/// camera recordings.
struct TraceEntry: Codable, Identifiable, Equatable {
    enum Source: Codable, Equatable {
        /// A loaded file, copied into the store as `<id>.<extension>`.
        case file(fileExtension: String)
        /// A camera recording in the recordings folder, by file name. It
        /// stays there; the store only remembers whether it's shown.
        case recording(fileName: String)
    }

    var id: String
    var name: String
    var source: Source
    var isShown: Bool
    /// Lines on the ground, draped over the map.
    var hasLines: Bool
    /// A track: drawn as a tube and flown along.
    var hasTrack: Bool
    /// Where to go to see it.
    var place: Place?

    static func recordingID(fileName: String) -> String { "recording:\(fileName)" }
}

/// The trace files the user has loaded and their camera recordings, with
/// whether each is shown. Loaded files are copied into `directory`, so they
/// stay loaded across launches until removed; `index.json` there lists the
/// entries in order. Recordings stay in their own folder and come and go
/// with it (`syncRecordings`).
///
/// A loaded GeoJSON file is all lines; a KML file has lines, a track, or
/// both (KMLFile). Each file's lines are kept ready to drape, as a features
/// array (`<id>.features.json`), so the shown ones join quickly
/// (`linesCollection`).
struct TraceStore {
    let directory: URL
    let recordingsDirectory: URL
    private(set) var entries: [TraceEntry] = []

    private var indexURL: URL { directory.appending(path: "index.json") }

    /// Reads the index; a missing or unreadable one is an empty list.
    init(directory: URL, recordingsDirectory: URL) {
        self.directory = directory
        self.recordingsDirectory = recordingsDirectory
        if let data = try? Data(contentsOf: indexURL),
           let entries = try? JSONDecoder().decode([TraceEntry].self, from: data) {
            self.entries = entries
        }
    }

    // MARK: Loading files

    /// Reads a GeoJSON or KML file, copies it and its lines into `directory`
    /// under a new ID, and returns its entry, shown, without adding it to
    /// the index: that's `insert`'s job, on the caller's side. Slow for big
    /// files, so it's static, for running off the main thread.
    static func prepare(_ data: Data, fileExtension: String, name: String, in directory: URL) throws -> TraceEntry {
        let fileExtension = fileExtension.lowercased()
        let id = UUID().uuidString
        var lines: TraceFile?
        var track: Track?
        if fileExtension == "kml" {
            let kml = try KMLFile(data: data)
            let ground = kml.groundLines
            if !ground.isEmpty { lines = try TraceFile(lines: ground, name: name) }
            track = kml.track(name: name)
        } else {
            lines = try TraceFile(geoJSON: data, name: name)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(id).\(fileExtension)"), options: .atomic)
        if let lines {
            try lines.features.write(to: featuresURL(id, in: directory), options: .atomic)
        }
        return TraceEntry(id: id, name: name, source: .file(fileExtension: fileExtension), isShown: true,
                          hasLines: lines != nil, hasTrack: track != nil, place: track?.start ?? lines?.place)
    }

    /// Adds a prepared entry at the top of the list.
    mutating func insert(_ entry: TraceEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    /// Removes a loaded file and its copies. Recordings can't be removed
    /// here: they're the user's files.
    mutating func remove(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case .file(let fileExtension) = entries[index].source else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: "\(id).\(fileExtension)"))
        try? FileManager.default.removeItem(at: Self.featuresURL(id, in: directory))
        entries.remove(at: index)
        save()
    }

    mutating func setShown(id: String, _ isShown: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isShown != isShown else { return }
        entries[index].isShown = isShown
        save()
    }

    // MARK: Recordings

    /// Adds recordings that are new in the folder, hidden, at the top of
    /// the list, newest first, and drops those that are gone. Returns
    /// whether anything changed.
    @discardableResult
    mutating func syncRecordings() -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingsDirectory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        let names = Set(files.map(\.lastPathComponent).filter {
            $0.hasPrefix("Track ") && $0.hasSuffix(".\(CameraTrack.fileExtension)")
        })
        let before = entries
        entries.removeAll {
            if case .recording(let fileName) = $0.source { return !names.contains(fileName) }
            return false
        }
        let known = Set(entries.compactMap { entry -> String? in
            if case .recording(let fileName) = entry.source { return fileName }
            return nil
        })
        // Oldest first, so the newest ends up on top.
        for fileName in names.subtracting(known).sorted() {
            let url = recordingsDirectory.appending(path: fileName)
            let start = (try? CameraTrack.read(url))?.start
            entries.insert(TraceEntry(id: TraceEntry.recordingID(fileName: fileName),
                                      name: url.deletingPathExtension().lastPathComponent,
                                      source: .recording(fileName: fileName), isShown: false,
                                      hasLines: false, hasTrack: true, place: start), at: 0)
        }
        guard entries != before else { return false }
        save()
        return true
    }

    // MARK: Contents

    /// The file behind an entry: the store's copy, or the recording.
    func url(of entry: TraceEntry) -> URL {
        switch entry.source {
        case .file(let fileExtension): directory.appending(path: "\(entry.id).\(fileExtension)")
        case .recording(let fileName): recordingsDirectory.appending(path: fileName)
        }
    }

    /// An entry's track, read from its file; nil if it has none.
    func track(of entry: TraceEntry) throws -> Track? {
        guard entry.hasTrack else { return nil }
        let url = url(of: entry)
        switch entry.source {
        case .file:
            return try KMLFile(data: Data(contentsOf: url)).track(name: entry.name)
        case .recording:
            return try CameraTrack.read(url)
        }
    }

    /// The shown entries' lines as one GeoJSON FeatureCollection, or nil if
    /// none have any.
    func linesCollection() -> Data? {
        let arrays = entries.filter { $0.isShown && $0.hasLines }
            .compactMap { try? Data(contentsOf: Self.featuresURL($0.id, in: directory)) }
        return arrays.isEmpty ? nil : TraceFile.collection(arrays)
    }

    private static func featuresURL(_ id: String, in directory: URL) -> URL {
        directory.appending(path: "\(id).features.json")
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            print("[AlsoMaps] couldn't save the traces list: \(error)")
        }
    }
}
