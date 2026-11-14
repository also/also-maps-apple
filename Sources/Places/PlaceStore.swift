import Foundation
import Observation
import UniformTypeIdentifiers
import os

extension UTType {
    /// `.alsomaps`: places as GeoJSON (PlaceGeoJSON).
    static let alsoMapsPlaces = UTType(exportedAs: "dev.also.maps.places", conformingTo: .geoJSON)
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

        var errorDescription: String? {
            switch self {
            case .unreadable: "The file couldn't be read."
            case .notGeoJSON: "The file isn't GeoJSON."
            case .noPlaces: "The file has no points to show as places."
            }
        }
    }

    private(set) var myMap: [Place] = []
    private(set) var imported: ImportedSet?

    @ObservationIgnored let directory: URL
    var myMapFile: URL { directory.appending(path: "My Map.alsomaps") }
    private var importedDirectory: URL { directory.appending(path: "Imported", directoryHint: .isDirectory) }

    /// Imported places' ids start with this, so they can't match a My Map or
    /// suggested place's.
    static let importedIDPrefix = "imported:"

    @ObservationIgnored private let log = Logger(subsystem: "dev.also.maps", category: "PlaceStore")

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: myMapFile) {
            myMap = (try? PlaceGeoJSON.places(from: data)) ?? []
        }
        if let file = try? FileManager.default.contentsOfDirectory(at: importedDirectory, includingPropertiesForKeys: nil)
            .first(where: { !$0.lastPathComponent.hasPrefix(".") }),
           let data = try? Data(contentsOf: file),
           let places = try? PlaceGeoJSON.places(from: data, idPrefix: Self.importedIDPrefix) {
            imported = ImportedSet(name: Self.importedName(file), places: places)
        }
    }

    // MARK: My Map

    func add(_ place: Place) {
        myMap.append(place)
        writeMyMap()
    }

    func rename(_ id: Place.ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = myMap.firstIndex(where: { $0.id == id }) else { return }
        myMap[index].name = name
        writeMyMap()
    }

    func remove(_ id: Place.ID) {
        myMap.removeAll { $0.id == id }
        writeMyMap()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        // As SwiftUI's List reports it: `destination` counts the moved rows.
        let moving = source.map { myMap[$0] }
        let insertion = destination - source.count(in: 0..<destination)
        for index in source.reversed() { myMap.remove(at: index) }
        myMap.insert(contentsOf: moving, at: insertion)
        writeMyMap()
    }

    private func writeMyMap() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PlaceGeoJSON.data(for: myMap).write(to: myMapFile, options: .atomic)
        } catch {
            log.error("Couldn't write My Map: \(error)")
        }
    }

    // MARK: Imported

    /// Reads the places in a GeoJSON file and keeps a copy of it, replacing
    /// the imported set. A file that fails leaves the current set alone.
    @discardableResult
    func importFile(_ url: URL) throws(ImportError) -> ImportedSet {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw .unreadable }

        let places: [Place]
        do { places = try PlaceGeoJSON.places(from: data, idPrefix: Self.importedIDPrefix) } catch {
            throw .notGeoJSON
        }
        guard !places.isEmpty else { throw .noPlaces }

        let set = ImportedSet(name: Self.importedName(url), places: places)
        do {
            try? FileManager.default.removeItem(at: importedDirectory)
            try FileManager.default.createDirectory(at: importedDirectory, withIntermediateDirectories: true)
            try data.write(to: importedDirectory.appending(path: url.lastPathComponent), options: .atomic)
        } catch {
            // Still shown; it just won't be there next launch.
            log.error("Couldn't keep the imported file: \(error)")
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
