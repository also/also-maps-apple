import Foundation
import simd

/// Where photos were taken, ready to draw as dots: one per spot, as photos
/// taken a few steps apart would land on the same overlay pixels anyway.
struct PhotoPoints {
    /// Longitude then latitude, in degrees, as double2 per point
    /// (CNTileStreamer.showPointsOverlay).
    private(set) var coordinates = Data()
    private(set) var count = 0
    /// How many photos had a usable position, including those sharing a spot.
    private(set) var photoCount = 0

    private var latitudes: [Double] = []
    private var longitudes: [Double] = []
    private var seen: Set<SIMD2<Int32>> = []

    /// Spots closer than about a metre (1e-5°) count as one.
    private static let spotsPerDegree = 100_000.0

    init() {}

    /// Adds a photo's position. (0, 0) and out-of-range values are what
    /// cameras and editors write when they have no fix, so they're skipped.
    mutating func add(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              latitude != 0 || longitude != 0 else { return }
        photoCount += 1
        let spot = SIMD2(Int32((latitude * Self.spotsPerDegree).rounded()),
                         Int32((longitude * Self.spotsPerDegree).rounded()))
        guard seen.insert(spot).inserted else { return }
        count += 1
        latitudes.append(latitude)
        longitudes.append(longitude)
        withUnsafeBytes(of: SIMD2<Double>(longitude, latitude)) { coordinates.append(contentsOf: $0) }
    }

    /// A view of where most of the photos were taken.
    func place(name: String) -> Place {
        Place.framing(id: "photos", name: name, latitudes: latitudes, longitudes: longitudes)
    }
}
