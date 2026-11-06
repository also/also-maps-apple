#if !os(tvOS)
import CoreLocation
import Foundation
import Photos

/// Reads where each photo and video in the user's Photos library was taken.
/// Only positions are read; no image data is loaded and nothing leaves the
/// device.
enum PhotoLibraryLocations {
    enum Failure: LocalizedError {
        case denied
        case noLocations

        var errorDescription: String? {
            switch self {
            case .denied: "Also Maps doesn't have access to your photos. You can allow it in Settings, under Privacy & Security, Photos."
            case .noLocations: "None of your photos have a location."
            }
        }
    }

    /// Whether the library can be read without asking.
    static var isAuthorized: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: true
        default: false
        }
    }

    /// Asks for access if it hasn't been decided, then reads the library off
    /// the main thread. With limited access, only the photos the user chose.
    static func load() async throws -> PhotoPoints {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw Failure.denied }
        let started = Date()
        let points = await Task.detached(priority: .userInitiated) { read() }.value
        print("[AlsoMaps] read \(points.photoCount) photo locations, \(points.count) spots, in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        guard points.count > 0 else { throw Failure.noLocations }
        return points
    }

    private static func read() -> PhotoPoints {
        let options = PHFetchOptions()
        // Hidden photos stay hidden.
        options.includeHiddenAssets = false
        let assets = PHAsset.fetchAssets(with: options)
        var points = PhotoPoints()
        assets.enumerateObjects { asset, _, _ in
            guard let coordinate = asset.location?.coordinate,
                  CLLocationCoordinate2DIsValid(coordinate) else { return }
            points.add(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        return points
    }
}
#endif
