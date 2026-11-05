import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

/// An ImageIO properties dictionary shaped like an iPhone photo's: unsigned
/// coordinates with their refs, numbers as NSNumber.
private func iPhoneProperties(orientation: Int = 1, direction: Double? = 271.3, directionRef: String = "T",
                              altitude: Double = 12.5, altitudeRef: Int = 0,
                              equivalent: Double? = 26) -> [String: Any] {
    var gps: [String: Any] = [
        "Latitude": NSNumber(value: 37.7955), "LatitudeRef": "N",
        "Longitude": NSNumber(value: 122.3937), "LongitudeRef": "W",
        "Altitude": NSNumber(value: altitude), "AltitudeRef": NSNumber(value: altitudeRef),
        "HPositioningError": NSNumber(value: 4.7),
    ]
    if let direction {
        gps["ImgDirection"] = NSNumber(value: direction)
        gps["ImgDirectionRef"] = directionRef
    }
    var exif: [String: Any] = [
        "FocalLength": NSNumber(value: 6.765),
        "PixelXDimension": NSNumber(value: 4032), "PixelYDimension": NSNumber(value: 3024),
        "DateTimeOriginal": "2026:05:01 14:03:22",
    ]
    if let equivalent { exif["FocalLenIn35mmFilm"] = NSNumber(value: equivalent) }
    return [
        "PixelWidth": NSNumber(value: 4032), "PixelHeight": NSNumber(value: 3024),
        "Orientation": NSNumber(value: orientation),
        "{GPS}": gps, "{Exif}": exif, "{TIFF}": ["Orientation": NSNumber(value: orientation)],
    ]
}

struct PhotoMetadataTests {
    @Test
    func readsSignedCoordinatesAndAltitude() {
        let m = PhotoMetadata(properties: iPhoneProperties())
        #expect(m.latitude == 37.7955)
        #expect(m.longitude == -122.3937)
        #expect(m.altitude == 12.5)
        #expect(m.horizontalError == 4.7)
        #expect(m.direction == 271.3)
        #expect(m.directionReference == .trueNorth)
        #expect(m.focalLength35mm == 26)
        #expect(m.pixelWidth == 4032 && m.pixelHeight == 3024)
        #expect(m.dateTaken == "2026:05:01 14:03:22")
        #expect(m.hasLocation)
    }

    @Test
    func southWestAndBelowSeaLevel() {
        var properties = iPhoneProperties(altitude: 28, altitudeRef: 1)
        var gps = properties["{GPS}"] as! [String: Any]
        gps["LatitudeRef"] = "S"
        gps["LongitudeRef"] = "E"
        properties["{GPS}"] = gps
        let m = PhotoMetadata(properties: properties)
        #expect(m.latitude == -37.7955)
        #expect(m.longitude == 122.3937)
        #expect(m.altitude == -28)
    }

    @Test
    func noGPSIsNoLocation() {
        var properties = iPhoneProperties()
        properties["{GPS}"] = nil
        let m = PhotoMetadata(properties: properties)
        #expect(!m.hasLocation)
        #expect(m.direction == nil)
        #expect(PhotoPose.camera(m, ground: 10) == nil)
    }

    @Test
    func zeroEquivalentMeansUnknown() {
        let m = PhotoMetadata(properties: iPhoneProperties(equivalent: 0))
        #expect(m.focalLength35mm == nil)
    }

    @Test
    func orientationFallsBackToTIFFAndIsRangeChecked() {
        var properties = iPhoneProperties(orientation: 6)
        properties["Orientation"] = nil
        #expect(PhotoMetadata(properties: properties).orientation == 6)
        properties["{TIFF}"] = ["Orientation": NSNumber(value: 42)]
        #expect(PhotoMetadata(properties: properties).orientation == 1)
    }

    @Test
    func emptyPropertiesHaveNothing() {
        let m = PhotoMetadata(properties: [:])
        #expect(m == PhotoMetadata())
        #expect(PhotoGeometry.fieldOfView(m) == nil)
    }
}

struct PhotoGeometryTests {
    /// A 3:2 image with a 50 mm equivalent is a full-frame 50 mm: 2·atan(18/50) across.
    @Test
    func equivalentOnAThreeByTwoFrameIsFullFrame() throws {
        var m = PhotoMetadata()
        m.pixelWidth = 6000
        m.pixelHeight = 4000
        m.focalLength35mm = 50
        let fov = try #require(PhotoGeometry.fieldOfView(m))
        #expect(fov.source == .equivalent35mm)
        #expect(abs(fov.horizontal - 2 * atan(18.0 / 50)) < 1e-12)
        #expect(abs(fov.vertical - 2 * atan(12.0 / 50)) < 1e-12)
    }

    /// Equivalence is by the diagonal, so a 4:3 image keeps the full frame's diagonal angle.
    @Test
    func equivalentKeepsTheDiagonalAngle() throws {
        let fov = try #require(PhotoGeometry.fieldOfView(PhotoMetadata(properties: iPhoneProperties())))
        let diagonal = 2 * atan((pow(tan(fov.horizontal / 2), 2) + pow(tan(fov.vertical / 2), 2)).squareRoot())
        #expect(abs(diagonal - 2 * atan(PhotoGeometry.fullFrameDiagonal / 52)) < 1e-12)
        #expect(abs(fov.aspect - 4.0 / 3) < 1e-12)
        // About 67.3° by 53.1° for the iPhone's 26 mm.
        #expect(abs(fov.horizontal / degrees - 67.3) < 0.05)
        #expect(abs(fov.vertical / degrees - 53.06) < 0.05)
    }

    @Test(arguments: [5, 6, 7, 8])
    func quarterTurnsSwapWidthAndHeight(orientation: Int) throws {
        let landscape = try #require(PhotoGeometry.fieldOfView(PhotoMetadata(properties: iPhoneProperties())))
        let portrait = try #require(PhotoGeometry.fieldOfView(
            PhotoMetadata(properties: iPhoneProperties(orientation: orientation))))
        #expect(abs(portrait.horizontal - landscape.vertical) < 1e-12)
        #expect(abs(portrait.vertical - landscape.horizontal) < 1e-12)
        let size = PhotoGeometry.displaySize(pixelWidth: 4032, pixelHeight: 3024, orientation: orientation)
        #expect(size.width == 3024 && size.height == 4032)
    }

    @Test(arguments: [1, 2, 3, 4])
    func uprightAndFlippedKeepTheirShape(orientation: Int) throws {
        let fov = try #require(PhotoGeometry.fieldOfView(
            PhotoMetadata(properties: iPhoneProperties(orientation: orientation))))
        #expect(fov.horizontal > fov.vertical)
    }

    /// 50 mm on a 36 mm-wide sensor of 6000 px: the resolution in pixels per inch.
    @Test
    func sensorSizeFromTheFocalPlaneResolution() throws {
        var m = PhotoMetadata()
        m.pixelWidth = 6000
        m.pixelHeight = 4000
        m.focalLength = 50
        m.focalPlaneXResolution = 6000 / (36 / 25.4)
        m.focalPlaneResolutionUnit = 2
        let fov = try #require(PhotoGeometry.fieldOfView(m))
        #expect(fov.source == .sensor)
        #expect(abs(fov.horizontal - 2 * atan(18.0 / 50)) < 1e-9)
        #expect(abs(fov.vertical - 2 * atan(12.0 / 50)) < 1e-9)
    }

    @Test
    func implausibleSensorFallsBackToAssumed() throws {
        var m = PhotoMetadata()
        m.pixelWidth = 6000
        m.pixelHeight = 4000
        m.focalLength = 50
        m.focalPlaneXResolution = 1  // A 6 m sensor.
        m.focalPlaneResolutionUnit = 4
        let fov = try #require(PhotoGeometry.fieldOfView(m))
        #expect(fov.source == .assumed)
    }

    @Test
    func headingIsWrappedAndFlagsMagnetic() throws {
        let t = try #require(PhotoGeometry.heading(PhotoMetadata(properties: iPhoneProperties(direction: 450))))
        #expect(abs(t.heading - 90 * degrees) < 1e-12)
        #expect(!t.isMagnetic)
        let m = try #require(PhotoGeometry.heading(PhotoMetadata(properties: iPhoneProperties(directionRef: "M"))))
        #expect(m.isMagnetic)
        #expect(abs(m.heading - 271.3 * degrees) < 1e-12)
        let negative = try #require(PhotoGeometry.heading(PhotoMetadata(properties: iPhoneProperties(direction: -10))))
        #expect(abs(negative.heading - 350 * degrees) < 1e-12)
        #expect(PhotoGeometry.heading(PhotoMetadata(properties: iPhoneProperties(direction: nil))) == nil)
    }
}

struct PhotoPoseTests {
    @Test
    func eyeIsAboveTheGroundUnlessClearlyHigher() throws {
        let near = try #require(PhotoPose.eyeHeight(ground: -20, recordedAltitude: 12))
        #expect(near.source == .ground)
        #expect(abs(near.height - (-18.4)) < 1e-12)
        let high = try #require(PhotoPose.eyeHeight(ground: -20, recordedAltitude: 300))
        #expect(high.source == .recorded)
        #expect(high.height == 300)
        // GPS altitude far *below* the ground is noise, never believed.
        #expect(PhotoPose.eyeHeight(ground: 400, recordedAltitude: 0)?.source == .ground)
        #expect(PhotoPose.eyeHeight(ground: nil, recordedAltitude: 12)?.source == .recorded)
        #expect(PhotoPose.eyeHeight(ground: nil, recordedAltitude: nil) == nil)
    }

    @Test
    func cameraStandsWhereThePhotoWasTakenLookingItsWay() throws {
        let m = PhotoMetadata(properties: iPhoneProperties())
        let camera = try #require(PhotoPose.camera(m, ground: -25))
        #expect(camera.latitude == 37.7955 && camera.longitude == -122.3937)
        #expect(abs(camera.height - (-23.4)) < 1e-12)
        #expect(abs(NavigationOperations.wrapped(camera.heading - 271.3 * degrees)) < 1e-12)
        #expect(camera.pitch == 0)
    }

    @Test
    func adjustmentNudgesHeadingAndPitch() throws {
        let m = PhotoMetadata(properties: iPhoneProperties(direction: 359))
        let camera = try #require(PhotoPose.camera(m, ground: 0,
                                                   adjustment: PhotoAdjustment(heading: 3 * degrees, pitch: 5 * degrees)))
        #expect(abs(NavigationOperations.wrapped(camera.heading - 2 * degrees)) < 1e-12)
        #expect(abs(camera.pitch - 5 * degrees) < 1e-12)
        let steep = try #require(PhotoPose.camera(m, ground: 0, adjustment: PhotoAdjustment(pitch: 3)))
        #expect(steep.pitch < .pi / 2)
    }

    @Test
    func noDirectionFacesNorth() throws {
        let camera = try #require(PhotoPose.camera(PhotoMetadata(properties: iPhoneProperties(direction: nil)), ground: 0))
        #expect(camera.heading == 0)
    }

    /// The frame and the scene agree: its edges are the photo's half-angles from the eye.
    @Test
    func frameSubtendsTheFieldOfView() {
        let fov = PhotoFieldOfView(horizontal: 60 * degrees, vertical: 40 * degrees, source: .assumed)
        let size = PhotoPose.frameSize(fov, distance: 3)
        #expect(abs(atan(size.width / 2 / 3) - 30 * degrees) < 1e-12)
        #expect(abs(atan(size.height / 2 / 3) - 20 * degrees) < 1e-12)
    }

    @Test
    func screenSizeMatchesTheWindowCamera() {
        let window = 45 * degrees
        let same = PhotoFieldOfView(horizontal: 60 * degrees, vertical: window, source: .assumed)
        let size = PhotoPose.screenSize(same, windowFieldOfView: window, viewportHeight: 800)
        #expect(abs(size.height - 800) < 1e-9)
        #expect(abs(size.width - 800 * tan(30 * degrees) / tan(22.5 * degrees)) < 1e-9)
    }

    @Test
    func windowWidensToShowThePhoto() {
        let portrait = PhotoFieldOfView(horizontal: 53 * degrees, vertical: 67 * degrees, source: .assumed)
        let fov = PhotoPose.windowFieldOfView(toShow: portrait, aspect: 1.6, margin: 0.1, minimum: 45 * degrees)
        let size = PhotoPose.screenSize(portrait, windowFieldOfView: fov, viewportHeight: 1000)
        #expect(size.height <= 1000 / 1.1 + 1e-6)
        #expect(size.width <= 1600 / 1.1 + 1e-6)
        // A narrow photo leaves the window as it is.
        let tele = PhotoFieldOfView(horizontal: 20 * degrees, vertical: 15 * degrees, source: .assumed)
        #expect(PhotoPose.windowFieldOfView(toShow: tele, aspect: 1.6, minimum: 45 * degrees) == 45 * degrees)
    }

    /// A marker's photo faces back toward the photographer, upright and level.
    @Test(arguments: [0.0, 90, 271.3])
    func markerFacesBackAlongTheHeading(headingDegrees: Double) {
        let rotation = PhotoPose.markerRotation(latitude: 37.7955, longitude: -122.3937,
                                                heading: headingDegrees * degrees)
        let camera = CameraPose(latitude: 37.7955, longitude: -122.3937, height: 0,
                                heading: headingDegrees * degrees, pitch: 0)
        let basis = camera.basis
        #expect(simd_distance(rotation.act(SIMD3(0, 0, 1)), -basis.forward) < 1e-9)
        #expect(simd_distance(rotation.act(SIMD3(1, 0, 0)), basis.right) < 1e-9)
        #expect(simd_distance(rotation.act(SIMD3(0, 1, 0)), basis.up) < 1e-9)
    }
}
