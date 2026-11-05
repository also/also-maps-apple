import CoreGraphics
import Foundation
import Observation
import PhotosUI
import SwiftUI

/// What a map does when the user goes to a photo or adjusts it. MapModel
/// (visionOS) and ScreenMap (the Mac) each implement it over their own
/// camera.
@MainActor
protocol PhotoSessionHost: AnyObject {
    /// Jump the camera to the photo's pose and show it framed.
    func standInPhoto(_ id: PlacedPhoto.ID)
    /// Stop showing it; the camera stays where it is.
    func leavePhoto()
    /// The active photo's adjustment changed: move the camera to match.
    func activePhotoAdjusted()
    /// Where "photos near here" searches around.
    var photoSearchCentre: GeoCoordinate { get }
}

/// One of the user's photos, placed in the world.
struct PlacedPhoto: Identifiable {
    let id = UUID()
    var name: String
    var metadata: PhotoMetadata
    var fieldOfView: PhotoFieldOfView
    var image: CGImage
    var thumbnail: CGImage
    var locationSource: ImportedPhoto.LocationSource
    /// The ground beneath the photo, metres above the ellipsoid, sampled
    /// from the tiles while the app runs. Google's terms don't allow storing
    /// it, so it's never written anywhere and goes when the session does.
    var ground: Double?
    var adjustment = PhotoAdjustment.none

    var coordinate: GeoCoordinate? {
        guard let latitude = metadata.latitude, let longitude = metadata.longitude else { return nil }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    /// The camera standing in the photo, or nil before there's any height.
    var camera: CameraPose? { PhotoPose.camera(metadata, ground: ground, adjustment: adjustment) }

    /// Radians clockwise from north (true, or magnetic used as true), plus
    /// the user's nudge.
    var heading: Double { (PhotoGeometry.heading(metadata)?.heading ?? 0) + adjustment.heading }
}

/// The photos picked this session, which one is being stood in, and its
/// frame's opacity; shared by visionOS and the Mac. Photos stay in memory
/// only: nothing is uploaded or saved, and quitting forgets them. (To keep
/// them, store the picker items' asset identifiers, which need library
/// access to resolve again; see notes/photos-in-place.md.)
@MainActor
@Observable
final class PhotoSession {
    private(set) var photos: [PlacedPhoto] = []
    /// The photo the camera is standing in, framed over the scene.
    private(set) var activeID: PlacedPhoto.ID?
    /// 1 shows only the photo, 0 only the world.
    var frameOpacity = 0.7
    private(set) var isImporting = false
    /// The last import's outcome, for the controls.
    private(set) var message: String?

    @ObservationIgnored weak var host: PhotoSessionHost?
    /// Asks the tiles for the ground at a point (lowest of a few samples a
    /// metre or two apart), calling back on the main thread. Returns false
    /// if there's nothing to ask yet (no key, not streaming).
    @ObservationIgnored var sampleGround: (@MainActor (GeoCoordinate, @escaping @Sendable (Double) -> Void) -> Bool)?
    /// The markers and the frame; the host adds the root to its scene.
    @ObservationIgnored let overlay = PhotoOverlay()

    @ObservationIgnored private var sampling: Set<PlacedPhoto.ID> = []
    @ObservationIgnored private var lastFailure: [PlacedPhoto.ID: Date] = [:]

    var active: PlacedPhoto? { activeID.flatMap { id in photos.first { $0.id == id } } }

    func photo(_ id: PlacedPhoto.ID) -> PlacedPhoto? { photos.first { $0.id == id } }

    // MARK: Adding

    func add(_ items: [PhotosPickerItem]) async {
        isImporting = true
        defer { isImporting = false }
        var imported: [ImportedPhoto] = []
        for item in items {
            if let photo = await PhotoImporter.load(item) { imported.append(photo) }
        }
        add(imported, failed: items.count - imported.count)
    }

    /// Stretch goal: the library's photos taken near the host's camera.
    func addNearby(radius: Double = 2_000, limit: Int = 40) async {
        guard let centre = host?.photoSearchCentre else { return }
        isImporting = true
        defer { isImporting = false }
        let found = await PhotoImporter.photos(near: centre, radius: radius, limit: limit)
        // Skip what's already here (picked earlier, or an earlier search).
        let fresh = found.filter { candidate in
            !photos.contains { $0.metadata == candidate.metadata }
        }
        add(fresh, failed: 0)
        if found.isEmpty { message = "No photos in your library within \(Int(radius / 1000)) km, or no access." }
    }

    private func add(_ imported: [ImportedPhoto], failed: Int) {
        var unplaced = 0
        for photo in imported {
            guard photo.metadata.hasLocation, let fov = PhotoGeometry.fieldOfView(photo.metadata) else {
                unplaced += 1
                continue
            }
            photos.append(PlacedPhoto(name: Self.name(photo.metadata, index: photos.count + 1),
                                      metadata: photo.metadata, fieldOfView: fov,
                                      image: photo.image, thumbnail: photo.thumbnail,
                                      locationSource: photo.locationSource))
        }
        var notes: [String] = []
        if unplaced > 0 { notes.append("\(unplaced) without a location") }
        if failed > 0 { notes.append("\(failed) couldn't be read") }
        message = notes.isEmpty ? nil : "Skipped " + notes.joined(separator: ", ") + "."
        requestGrounds()
    }

    /// "1 May 2026, 14:03", from EXIF's "2026:05:01 14:03:22".
    private static func name(_ metadata: PhotoMetadata, index: Int) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let text = metadata.dateTaken, let date = parser.date(from: text) else { return "Photo \(index)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    func removeAll() {
        if activeID != nil { host?.leavePhoto() }
        photos = []
        sampling = []
        lastFailure = [:]
        message = nil
    }

    // MARK: Ground

    /// Samples the ground under every photo that doesn't have it yet. A
    /// failed sample (often: tiles there aren't loaded or are outside what's
    /// streamed) is retried after a while. Called on adding and from the
    /// host's frame loop.
    func requestGrounds(now: Date = Date()) {
        guard let sampleGround else { return }
        for photo in photos where photo.ground == nil && !sampling.contains(photo.id) {
            if let failed = lastFailure[photo.id], now.timeIntervalSince(failed) < 10 { continue }
            guard let coordinate = photo.coordinate else { continue }
            let id = photo.id
            sampling.insert(id)
            let asked = sampleGround(coordinate) { [weak self] height in
                MainActor.assumeIsolated { self?.received(height, for: id) }
            }
            if !asked {
                sampling.remove(id)
                return
            }
        }
    }

    private func received(_ height: Double, for id: PlacedPhoto.ID) {
        sampling.remove(id)
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        guard height.isFinite else {
            lastFailure[id] = Date()
            return
        }
        photos[index].ground = min(max(height, -500), 9_000)
        #if DEBUG
        print("[AlsoMaps] photo \(photos[index].name): ground \(Int(height)) m, eye \(PhotoPose.eyeHeight(ground: photos[index].ground, recordedAltitude: photos[index].metadata.altitude).map { "\(Int($0.height)) m from \($0.source)" } ?? "unknown")")
        #endif
        // The camera stood in it before the ground was known: lift it now.
        if id == activeID { host?.activePhotoAdjusted() }
    }

    // MARK: Standing in a photo

    /// Called by the controls; the host moves the camera and calls `didStand`.
    func stand(in id: PlacedPhoto.ID) { host?.standInPhoto(id) }
    func leave() { host?.leavePhoto() }

    /// The host has the camera in this photo (or nil: in none).
    func setActive(_ id: PlacedPhoto.ID?) {
        guard activeID != id else { return }
        activeID = id
    }

    /// Nudges the active photo by `delta` radians and has the host follow.
    func nudge(heading: Double = 0, pitch: Double = 0) {
        guard let id = activeID, let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].adjustment.heading += heading
        photos[index].adjustment.pitch = min(max(photos[index].adjustment.pitch + pitch, -0.5), 0.5)
        host?.activePhotoAdjusted()
    }

    func resetAdjustment() {
        guard let id = activeID, let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].adjustment = .none
        host?.activePhotoAdjusted()
    }
}
