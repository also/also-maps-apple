import Foundation
import Testing

@Suite struct PhotoPointsTests {
    @Test func packsLongitudeThenLatitude() {
        var points = PhotoPoints()
        points.add(latitude: 42.36, longitude: -71.06)
        #expect(points.count == 1)
        let values = points.coordinates.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        #expect(values == [-71.06, 42.36])
    }

    @Test func mergesPhotosTakenInTheSameSpot() {
        var points = PhotoPoints()
        points.add(latitude: 42.360001, longitude: -71.060001)
        points.add(latitude: 42.360002, longitude: -71.060002)
        points.add(latitude: 42.37, longitude: -71.06)
        #expect(points.count == 2)
        #expect(points.photoCount == 3)
        #expect(points.coordinates.count == 2 * MemoryLayout<SIMD2<Double>>.size)
    }

    @Test func skipsPositionsWithoutAFix() {
        var points = PhotoPoints()
        points.add(latitude: 0, longitude: 0)
        points.add(latitude: .nan, longitude: 10)
        points.add(latitude: 91, longitude: 10)
        points.add(latitude: 10, longitude: -181)
        #expect(points.count == 0)
        #expect(points.photoCount == 0)
    }

    @Test func framesWhereMostPhotosWere() {
        var points = PhotoPoints()
        for i in 0..<9 {
            points.add(latitude: 42.36 + Double(i) * 0.001, longitude: -71.06)
        }
        points.add(latitude: 48.85, longitude: 2.35)
        let place = points.place(name: "Photos")
        #expect(abs(place.latitude - 42.365) < 0.002)
        #expect(abs(place.longitude + 71.06) < 0.001)
        #expect(place.radius <= 50_000)
    }
}
