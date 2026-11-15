import Foundation
import Observation
import UniformTypeIdentifiers
import os

extension UTType {
    /// `.alsomaps`: Also Maps data as GeoJSON. Places for now (PlaceGeoJSON).
    static let alsoMaps = UTType(exportedAs: "dev.also.maps.document", conformingTo: .geoJSON)
}

/// The user's places: My Map, which they save places to, and the one file
/// they've imported. Both are kept as GeoJSON files in Application Support,
/// so they're there after the app quits:
///
/// - `My Map.alsomaps`, rewritten on every change and shared as is.
/// - `Imported/<the file's name>`, a byte-for-byte copy of the imported
///   file. Importing another replaces it. Its name names the set.
@MainActor @Observable
final class PlaceStore {
    /// Under the bundle id, since the unsandboxed Mac Debug build shares
    /// Application Support with every other app.
    static let shared = PlaceStore(
        directory: URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.also.maps", directoryHint: .isDirectory)
            .appending(path: "Places", directoryHint: .isDirectory))

    struct ImportedSet: Equatable {
        /// The file's name without its extension.
        var name: String
        var places: [Place]
    }

    enum ImportError: LocalizedError, Equatable {
        case unreadable
        case notGeoJSON
        case noPlaces
        /// Read, but the copy to keep couldn't be written.
        case notKept(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "The file couldn't be read."
            case .notGeoJSON: "The file isn't GeoJSON."
            case .noPlaces: "The file has no points to show as places."
            case .notKept(let reason): "The file couldn't be kept. \(reason)"
            }
        }
    }

    /// My Map's file couldn't be written. My Map is left as it was.
    struct SaveError: LocalizedError, Equatable {
        var reason: String
        var errorDescription: String? { "My Map couldn't be saved. \(reason)" }
    }

    private(set) var myMap: [Place] = []
    private(set) var imported: ImportedSet?

    @ObservationIgnored let directory: URL
    var myMapFile: URL { directory.appending(path: "My Map.alsomaps") }
    private var importedDirectory: URL { directory.appending(path: "Imported", directoryHint: .isDirectory) }

    @ObservationIgnored private let log = Logger(subsystem: "dev.also.maps", category: "PlaceStore")

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: myMapFile) {
            myMap = (try? PlaceGeoJSON.places(from: data)) ?? []
        }
        if let file = try? FileManager.default.contentsOfDirectory(at: importedDirectory, includingPropertiesForKeys: nil)
            .first(where: { !$0.lastPathComponent.hasPrefix(".") }),
           let data = try? Data(contentsOf: file),
           let places = try? PlaceGeoJSON.places(from: data) {
            imported = ImportedSet(name: Self.importedName(file), places: places)
        }
    }

    // MARK: My Map

    // Each change is written before it's shown, so My Map never shows what
    // won't be there next launch.

    func add(_ place: Place) throws(SaveError) {
        try save(myMap + [place])
    }

    /// An empty name is ignored, keeping the old one.
    func rename(_ id: Place.ID, to name: String) throws(SaveError) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = myMap.firstIndex(where: { $0.id == id }) else { return }
        var places = myMap
        places[index].name = name
        try save(places)
    }

    func remove(_ ids: Set<Place.ID>) throws(SaveError) {
        try save(myMap.filter { !ids.contains($0.id) })
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws(SaveError) {
        // As SwiftUI's List reports it: `destination` counts the moved rows.
        var places = myMap
        let moving = source.map { places[$0] }
        let insertion = destination - source.count(in: 0..<destination)
        for index in source.reversed() { places.remove(at: index) }
        places.insert(contentsOf: moving, at: insertion)
        try save(places)
    }

    /// Writes `places` as My Map, then shows them.
    private func save(_ places: [Place]) throws(SaveError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PlaceGeoJSON.data(for: places).write(to: myMapFile, options: .atomic)
        } catch {
            log.error("Couldn't write My Map: \(error)")
            throw SaveError(reason: error.localizedDescription)
        }
        myMap = places
    }

    // MARK: Imported

    /// Reads the places in a GeoJSON file and keeps a copy of it, replacing
    /// the imported set. A file that fails, or can't be kept, leaves the
    /// current set alone.
    @discardableResult
    func importFile(_ url: URL) throws(ImportError) -> ImportedSet {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw .unreadable }

        let places: [Place]
        do { places = try PlaceGeoJSON.places(from: data) } catch {
            throw .notGeoJSON
        }
        guard !places.isEmpty else { throw .noPlaces }

        let set = ImportedSet(name: Self.importedName(url), places: places)
        // Written beside the kept copy first, so a failure leaves it there.
        let staging = directory.appending(path: "Importing", directoryHint: .isDirectory)
        let files = FileManager.default
        do {
            try? files.removeItem(at: staging)
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            try data.write(to: staging.appending(path: url.lastPathComponent))
            if files.fileExists(atPath: importedDirectory.path) {
                _ = try files.replaceItemAt(importedDirectory, withItemAt: staging)
            } else {
                try files.moveItem(at: staging, to: importedDirectory)
            }
        } catch {
            try? files.removeItem(at: staging)
            log.error("Couldn't keep the imported file: \(error)")
            throw .notKept(error.localizedDescription)
        }
        imported = set
        return set
    }

    /// The file's name without its extension, marked when it would read
    /// as the user's own My Map (an exported My Map opened again).
    static func importedName(_ file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        return name.localizedCaseInsensitiveCompare("My Map") == .orderedSame ? "\(name) (Imported)" : name
    }

    func removeImported() {
        try? FileManager.default.removeItem(at: importedDirectory)
        imported = nil
    }
}
