import Foundation

/// What a photo's own metadata says about where it was taken and with what
/// lens, read from an ImageIO properties dictionary (`CGImageSource`'s
/// properties at index 0). Foundation only, so it can be tested without
/// ImageIO; `PhotoImporter` does the reading.
///
/// Everything is optional: a screenshot has none of it, a photo with
/// location turned off has the lens but no GPS, and older cameras write a
/// focal length but no 35 mm equivalent.
struct PhotoMetadata: Equatable {
    /// Degrees, north and east positive.
    var latitude: Double?
    var longitude: Double?
    /// Metres above sea level (GPS altitude, negative below it). Not the
    /// ellipsoid: the two differ by the geoid, up to about ±100 m.
    var altitude: Double?
    /// The receiver's horizontal error estimate, metres, if it wrote one.
    var horizontalError: Double?

    enum DirectionReference: String, Equatable {
        case trueNorth = "T"
        case magneticNorth = "M"
    }
    /// Degrees clockwise from north: which way the camera faced
    /// (GPSImgDirection), against `directionReference`.
    var direction: Double?
    var directionReference: DirectionReference?

    /// Lens focal length, millimetres.
    var focalLength: Double?
    /// The 35 mm film equivalent focal length, millimetres.
    var focalLength35mm: Double?
    /// Pixels per `focalPlaneResolutionUnit` on the sensor, for working out
    /// its size when there's no 35 mm equivalent.
    var focalPlaneXResolution: Double?
    var focalPlaneYResolution: Double?
    /// EXIF's unit code: 2 inches, 3 centimetres (4 millimetres and 5
    /// micrometres are written by some cameras).
    var focalPlaneResolutionUnit: Int?

    /// The stored pixel size, before orientation is applied.
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// EXIF orientation, 1...8: how to turn the stored pixels to display
    /// them. 5–8 turn them a quarter turn, so width and height swap.
    var orientation = 1
    /// EXIF DateTimeOriginal as written ("2026:05:01 14:03:22"), for labels.
    var dateTaken: String?

    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// The keys ImageIO uses, as strings: the values of the matching
    /// kCGImageProperty… constants. `PhotoImporter` checks them against the
    /// constants in debug builds.
    enum Key {
        static let gps = "{GPS}"
        static let exif = "{Exif}"
        static let tiff = "{TIFF}"
        static let pixelWidth = "PixelWidth"
        static let pixelHeight = "PixelHeight"
        static let orientation = "Orientation"

        static let latitude = "Latitude"
        static let latitudeRef = "LatitudeRef"
        static let longitude = "Longitude"
        static let longitudeRef = "LongitudeRef"
        static let altitude = "Altitude"
        static let altitudeRef = "AltitudeRef"
        static let horizontalError = "HPositioningError"
        static let imgDirection = "ImgDirection"
        static let imgDirectionRef = "ImgDirectionRef"

        static let focalLength = "FocalLength"
        static let focalLength35mm = "FocalLenIn35mmFilm"
        static let focalPlaneXResolution = "FocalPlaneXResolution"
        static let focalPlaneYResolution = "FocalPlaneYResolution"
        static let focalPlaneResolutionUnit = "FocalPlaneResolutionUnit"
        static let pixelXDimension = "PixelXDimension"
        static let pixelYDimension = "PixelYDimension"
        static let dateTimeOriginal = "DateTimeOriginal"
    }

    init() {}

    init(properties: [String: Any]) {
        let gps = properties[Key.gps] as? [String: Any] ?? [:]
        let exif = properties[Key.exif] as? [String: Any] ?? [:]
        let tiff = properties[Key.tiff] as? [String: Any] ?? [:]

        // ImageIO gives latitude and longitude unsigned, with N/S and E/W
        // in the Ref keys.
        if let value = Self.double(gps[Key.latitude]) {
            latitude = (gps[Key.latitudeRef] as? String)?.uppercased() == "S" ? -abs(value) : abs(value)
        }
        if let value = Self.double(gps[Key.longitude]) {
            longitude = (gps[Key.longitudeRef] as? String)?.uppercased() == "W" ? -abs(value) : abs(value)
        }
        if let value = Self.double(gps[Key.altitude]) {
            // AltitudeRef 1 means below sea level.
            altitude = Self.int(gps[Key.altitudeRef]) == 1 ? -abs(value) : value
        }
        horizontalError = Self.double(gps[Key.horizontalError])
        direction = Self.double(gps[Key.imgDirection])
        if let reference = (gps[Key.imgDirectionRef] as? String)?.uppercased() {
            directionReference = DirectionReference(rawValue: reference)
        }

        focalLength = Self.double(exif[Key.focalLength])
        // 0 means unknown in EXIF.
        focalLength35mm = Self.double(exif[Key.focalLength35mm]).flatMap { $0 > 0 ? $0 : nil }
        focalPlaneXResolution = Self.double(exif[Key.focalPlaneXResolution])
        focalPlaneYResolution = Self.double(exif[Key.focalPlaneYResolution])
        focalPlaneResolutionUnit = Self.int(exif[Key.focalPlaneResolutionUnit])
        dateTaken = exif[Key.dateTimeOriginal] as? String

        pixelWidth = Self.int(properties[Key.pixelWidth]) ?? Self.int(exif[Key.pixelXDimension])
        pixelHeight = Self.int(properties[Key.pixelHeight]) ?? Self.int(exif[Key.pixelYDimension])
        let rawOrientation = Self.int(properties[Key.orientation]) ?? Self.int(tiff[Key.orientation]) ?? 1
        orientation = (1...8).contains(rawOrientation) ? rawOrientation : 1
    }

    /// ImageIO's numbers arrive as NSNumber; tests pass Swift numbers, and
    /// some writers store numbers as strings.
    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value.isFinite ? value : nil
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue.isFinite ? value.doubleValue : nil
        case let value as String: Double(value.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: value
        case let value as Double where value.isFinite: Int(value)
        case let value as NSNumber: value.intValue
        case let value as String: Int(value.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
}
