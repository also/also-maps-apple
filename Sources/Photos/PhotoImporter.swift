import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI

/// A photo read into memory: its metadata, a display-sized image and a
/// thumbnail. Nothing is written anywhere; it lives as long as the session.
struct ImportedPhoto: @unchecked Sendable {  // CGImage is immutable.
    var metadata: PhotoMetadata
    var image: CGImage
    var thumbnail: CGImage

    enum LocationSource: Equatable {
        /// The image data's own EXIF GPS block.
        case exif
        /// PhotoKit's PHAsset.location: the data the picker handed over had
        /// none.
        case photoLibrary
        case none
    }
    var locationSource: LocationSource
}

/// Reads photos from the system picker (and, for "near here", the library)
/// with ImageIO. See notes/photos-in-place.md for what each path needs.
enum PhotoImporter {
    /// The longest side of the image kept for the frame, pixels: sharp at
    /// the frame's size in the immersive space, and a few tens of MB at most
    /// for a session's worth of photos.
    static let imageSize = 2048
    static let thumbnailSize = 256

    // MARK: The picker

    /// Reads a picked item. With `photoLibrary: .shared()` on the picker the
    /// item carries the asset's identifier, which the library fallback needs.
    static func load(_ item: PhotosPickerItem) async -> ImportedPhoto? {
        let data: Data?
        do {
            // `.current` on the picker asks for the original encoding (HEIC
            // usually), not a transcoded JPEG, so the metadata comes too.
            // UNVERIFIED: whether the picker keeps the GPS block in that data
            // on visionOS 26 and macOS 26, or strips it (then the library
            // fallback below runs).
            data = try await item.loadTransferable(type: Data.self)
        } catch {
            print("[AlsoMaps] couldn't load a picked photo: \(error)")
            return nil
        }
        guard let data, var photo = await decode(data) else { return nil }
        #if DEBUG
        print("[AlsoMaps] picked photo: location \(photo.metadata.hasLocation ? "in EXIF" : "missing"), direction \(photo.metadata.direction.map { String(format: "%.1f°", $0) } ?? "none"), 35 mm \(photo.metadata.focalLength35mm.map { "\(Int($0)) mm" } ?? "none")")
        #endif
        if !photo.metadata.hasLocation, let identifier = item.itemIdentifier,
           let location = await libraryLocation(identifier: identifier) {
            photo.metadata.apply(location)
            photo.locationSource = .photoLibrary
        }
        return photo
    }

    // MARK: ImageIO

    /// Metadata and downsampled images from encoded image data, off the main
    /// thread.
    static func decode(_ data: Data) async -> ImportedPhoto? {
        await Task.detached(priority: .userInitiated) { decodeNow(data) }.value
    }

    private static func decodeNow(_ data: Data) -> ImportedPhoto? {
        #if DEBUG
        checkKeys()
        #endif
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let metadata = PhotoMetadata(properties: properties)
        // WithTransform applies the EXIF orientation, so both come out
        // upright: the displayed shape PhotoGeometry works in.
        func image(maxSize: Int) -> CGImage? {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let display = image(maxSize: imageSize), let thumbnail = image(maxSize: thumbnailSize) else { return nil }
        return ImportedPhoto(metadata: metadata, image: display, thumbnail: thumbnail,
                             locationSource: metadata.hasLocation ? .exif : .none)
    }

    #if DEBUG
    /// PhotoMetadata reads ImageIO's keys by their string values.
    private static func checkKeys() {
        typealias K = PhotoMetadata.Key
        assert(kCGImagePropertyGPSDictionary as String == K.gps)
        assert(kCGImagePropertyExifDictionary as String == K.exif)
        assert(kCGImagePropertyTIFFDictionary as String == K.tiff)
        assert(kCGImagePropertyPixelWidth as String == K.pixelWidth)
        assert(kCGImagePropertyOrientation as String == K.orientation)
        assert(kCGImagePropertyGPSLatitude as String == K.latitude)
        assert(kCGImagePropertyGPSAltitudeRef as String == K.altitudeRef)
        assert(kCGImagePropertyGPSHPositioningError as String == K.horizontalError)
        assert(kCGImagePropertyGPSImgDirection as String == K.imgDirection)
        assert(kCGImagePropertyGPSImgDirectionRef as String == K.imgDirectionRef)
        assert(kCGImagePropertyExifFocalLength as String == K.focalLength)
        assert(kCGImagePropertyExifFocalLenIn35mmFilm as String == K.focalLength35mm)
        assert(kCGImagePropertyExifFocalPlaneXResolution as String == K.focalPlaneXResolution)
        assert(kCGImagePropertyExifFocalPlaneResolutionUnit as String == K.focalPlaneResolutionUnit)
        assert(kCGImagePropertyExifDateTimeOriginal as String == K.dateTimeOriginal)
    }
    #endif

    // MARK: PhotoKit

    /// Whether the app may read the library (all of it, or what the user
    /// chose under limited access), asking the first time. Needs
    /// NSPhotoLibraryUsageDescription in the Info.plist.
    static func requestLibraryAccess() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return status == .authorized || status == .limited
    }

    /// The asset's location from the library, when the picked data had none.
    /// Asks for library access the first time this is needed.
    static func libraryLocation(identifier: String) async -> CLLocation? {
        guard await requestLibraryAccess() else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject?.location
    }

    /// Stretch goal: the library's photos taken within `radius` metres of
    /// `centre`, nearest first, read in full (for direction and lens) up to
    /// `limit`. Asks for library access first.
    static func photos(near centre: GeoCoordinate, radius: Double, limit: Int) async -> [ImportedPhoto] {
        guard await requestLibraryAccess() else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        // PhotoKit can't filter by location in the fetch, so walk them. Fine
        // for a spike; a big library takes a moment.
        var nearby: [(asset: PHAsset, distance: Double)] = []
        assets.enumerateObjects { asset, _, _ in
            guard let location = asset.location else { return }
            let coordinate = GeoCoordinate(latitude: location.coordinate.latitude,
                                           longitude: location.coordinate.longitude)
            let distance = GeoMath.distance(from: centre, to: coordinate)
            if distance <= radius { nearby.append((asset, distance)) }
        }
        nearby.sort { $0.distance < $1.distance }

        var photos: [ImportedPhoto] = []
        for (asset, _) in nearby.prefix(limit) {
            guard let data = await imageData(for: asset), var photo = await decode(data) else { continue }
            if !photo.metadata.hasLocation, let location = asset.location {
                photo.metadata.apply(location)
                photo.locationSource = .photoLibrary
            }
            photos.append(photo)
        }
        return photos
    }

    /// The asset's original data. Network access is allowed so photos whose
    /// originals are only in the user's iCloud library can be read; that's a
    /// download of their own photo, nothing is uploaded.
    private static func imageData(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

extension PhotoMetadata {
    /// Fills in the location from PhotoKit. Its altitude is CoreLocation's,
    /// above sea level like GPS altitude; its course is the direction of
    /// travel, not the camera's, so it isn't used as a direction.
    mutating func apply(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        if location.verticalAccuracy > 0 { altitude = location.altitude }
        if location.horizontalAccuracy > 0 { horizontalError = location.horizontalAccuracy }
    }
}
