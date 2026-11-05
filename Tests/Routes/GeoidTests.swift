import Testing

struct GeoidTests {
    /// Reference values are bilinear on GeographicLib's 15-minute EGM96
    /// grid; the 2° grid stays within 4 m of it almost everywhere.
    @Test(arguments: [
        (0.0, 0.0, 17.16),             // EGM96's well-known 17.16 m at 0°, 0°.
        (37.7955, -122.3937, -32.20),  // The Ferry Building.
        (27.9881, 86.925, -28.87),     // Everest.
        (4.7, 78.8, -106.96),          // The Indian Ocean low.
        (-4.5, 147.25, 77.99),         // The New Guinea high.
        (47.37, 8.54, 47.34),          // Zürich.
    ])
    func matchesEGM96(latitude: Double, longitude: Double, expected: Double) {
        #expect(abs(Geoid.height(latitude: latitude, longitude: longitude) - expected) < 4)
    }

    @Test func polesAreOneValueAtEveryLongitude() {
        #expect(abs(Geoid.height(latitude: 90, longitude: 0) - 13.61) < 0.1)
        #expect(abs(Geoid.height(latitude: 90, longitude: 123) - 13.61) < 0.1)
        #expect(abs(Geoid.height(latitude: -90, longitude: -45) - -29.53) < 0.1)
    }

    @Test func continuousAcrossTheAntimeridianAndLongitudeWraps() {
        let east = Geoid.height(latitude: -17, longitude: 179.999)
        let west = Geoid.height(latitude: -17, longitude: -179.999)
        #expect(abs(east - west) < 0.01)
        #expect(abs(Geoid.height(latitude: 10, longitude: -60) - Geoid.height(latitude: 10, longitude: 300)) < 1e-9)
    }

    @Test func seaLevelHeightsBecomeEllipsoidHeights() {
        let h = Geoid.ellipsoidHeight(meanSeaLevel: 100, latitude: 0, longitude: 0)
        #expect(abs(h - 117.16) < 0.5)
    }
}
