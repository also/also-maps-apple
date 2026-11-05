import Foundation

/// A photo's angular size as displayed (upright), radians, and how it was
/// worked out.
struct PhotoFieldOfView: Equatable {
    var horizontal: Double
    var vertical: Double

    enum Source: Equatable {
        /// From the 35 mm equivalent focal length.
        case equivalent35mm
        /// From the focal length and the sensor size the focal-plane
        /// resolution implies.
        case sensor
        /// Nothing usable in the metadata: a typical phone's main camera.
        case assumed
    }
    var source: Source

    /// Width over height, as displayed.
    var aspect: Double { tan(horizontal / 2) / tan(vertical / 2) }
}

/// Lens and orientation maths for placing a photo: its displayed shape,
/// its field of view and which way it faced. Foundation only.
enum PhotoGeometry {
    /// The diagonal of a 36 × 24 mm frame, millimetres. A "35 mm equivalent"
    /// focal length gives the same diagonal angle of view on that frame
    /// (CIPA DC-004), whatever the photo's own aspect ratio.
    static let fullFrameDiagonal = (36.0 * 36 + 24 * 24).squareRoot()

    /// Assumed when the metadata says nothing about the lens: the 35 mm
    /// equivalent of recent iPhones' main (1×) cameras.
    static let assumedEquivalentFocalLength = 26.0

    /// Whether an EXIF orientation turns the stored pixels a quarter turn
    /// (5–8), so the displayed width is the stored height.
    static func swapsAxes(orientation: Int) -> Bool { (5...8).contains(orientation) }

    /// The displayed pixel size: the stored size, turned by the orientation.
    static func displaySize(pixelWidth: Int, pixelHeight: Int, orientation: Int) -> (width: Int, height: Int) {
        swapsAxes(orientation: orientation) ? (pixelHeight, pixelWidth) : (pixelWidth, pixelHeight)
    }

    /// The displayed field of view: from the 35 mm equivalent if there is
    /// one, else from the focal length and sensor size, else assumed. Nil
    /// without a pixel size, since the shape is unknown.
    static func fieldOfView(_ metadata: PhotoMetadata) -> PhotoFieldOfView? {
        guard let width = metadata.pixelWidth, let height = metadata.pixelHeight, width > 0, height > 0
        else { return nil }
        let swaps = swapsAxes(orientation: metadata.orientation)

        // Tangents of the half-angles across the stored pixels.
        let stored: (x: Double, y: Double, source: PhotoFieldOfView.Source)
        if let equivalent = metadata.focalLength35mm {
            stored = diagonalEquivalent(focalLength: equivalent, width: width, height: height, source: .equivalent35mm)
        } else if let sensor = sensorSize(metadata, width: width, height: height),
                  let focal = metadata.focalLength, focal > 0 {
            stored = (sensor.width / (2 * focal), sensor.height / (2 * focal), .sensor)
        } else {
            stored = diagonalEquivalent(focalLength: assumedEquivalentFocalLength, width: width, height: height,
                                        source: .assumed)
        }
        let (x, y) = swaps ? (stored.y, stored.x) : (stored.x, stored.y)
        return PhotoFieldOfView(horizontal: 2 * atan(x), vertical: 2 * atan(y), source: stored.source)
    }

    /// Half-angle tangents across a `width` × `height` image whose diagonal
    /// sees what a 36 × 24 mm frame's would behind `focalLength` mm.
    private static func diagonalEquivalent(focalLength: Double, width: Int, height: Int,
                                           source: PhotoFieldOfView.Source)
        -> (x: Double, y: Double, source: PhotoFieldOfView.Source) {
        let halfDiagonal = fullFrameDiagonal / (2 * focalLength)
        let w = Double(width), h = Double(height)
        let diagonal = (w * w + h * h).squareRoot()
        return (halfDiagonal * w / diagonal, halfDiagonal * h / diagonal, source)
    }

    /// The sensor's size in millimetres across the stored pixels, from the
    /// focal-plane resolution, or nil if it's missing or implausible.
    static func sensorSize(_ metadata: PhotoMetadata, width: Int, height: Int) -> (width: Double, height: Double)? {
        guard let xResolution = metadata.focalPlaneXResolution, xResolution > 0,
              let unit = millimetres(perResolutionUnit: metadata.focalPlaneResolutionUnit)
        else { return nil }
        let yResolution = metadata.focalPlaneYResolution.flatMap { $0 > 0 ? $0 : nil } ?? xResolution
        let size = (width: Double(width) / xResolution * unit, height: Double(height) / yResolution * unit)
        // Some writers fill these in for a downscaled image, or wrongly:
        // anything outside phone to medium-format sizes is ignored.
        guard (1...80).contains(size.width), (1...80).contains(size.height) else { return nil }
        return size
    }

    private static func millimetres(perResolutionUnit unit: Int?) -> Double? {
        switch unit ?? 2 {  // EXIF's default is inches.
        case 2: 25.4
        case 3: 10
        case 4: 1
        case 5: 0.001
        default: nil
        }
    }

    /// The camera's heading, radians clockwise from true north, wrapped to
    /// [0, 2π), or nil if the photo didn't record one. A magnetic direction
    /// is used as if true (there's no magnetic model here), and says so:
    /// declination is under 15° in most populated places, and the user can
    /// nudge the heading to line the photo up.
    static func heading(_ metadata: PhotoMetadata) -> (heading: Double, isMagnetic: Bool)? {
        guard let direction = metadata.direction else { return nil }
        let wrapped = direction.truncatingRemainder(dividingBy: 360)
        let radians = (wrapped < 0 ? wrapped + 360 : wrapped) * .pi / 180
        // No reference is read as true: iPhones write "T", and a missing
        // reference is rare enough not to guess otherwise.
        return (radians, metadata.directionReference == .magneticNorth)
    }
}
