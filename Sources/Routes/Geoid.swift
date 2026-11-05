import Foundation

/// The EGM96 geoid's height above the WGS84 ellipsoid, roughly: mean sea
/// level, as GPS receivers and GPX files measure heights from, is this far
/// above the ellipsoid the app (and TrackPath) measures from. It ranges from
/// about −107 m (south of India) to +85 m (New Guinea).
///
/// Bilinear on a 2° grid (GeoidGrid.swift, from Scripts/make_geoid_grid.py):
/// within 4 m almost everywhere, which is well inside a GPS receiver's own
/// height error, and small next to the 10–20 m it corrects for most places.
enum Geoid {
    /// Decimetres, row by row from the north pole, decoded once.
    private static let grid: [Int16] = {
        guard let data = Data(base64Encoded: gridBase64, options: .ignoreUnknownCharacters),
              data.count == gridRows * gridColumns * 2
        else {
            assertionFailure("GeoidGrid.swift is damaged")
            return []
        }
        return stride(from: 0, to: data.count, by: 2).map { i in
            Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)
        }
    }()

    /// Metres from the ellipsoid up to the geoid at a point, degrees.
    static func height(latitude: Double, longitude: Double) -> Double {
        let grid = self.grid
        guard !grid.isEmpty, latitude.isFinite, longitude.isFinite else { return 0 }
        let y = (90 - min(max(latitude, -90), 90)) / gridStep
        var x = longitude.truncatingRemainder(dividingBy: 360) / gridStep
        if x < 0 { x += Double(gridColumns) }
        let row = min(Int(y), gridRows - 2), column = Int(x) % gridColumns
        let fy = y - Double(row), fx = x - x.rounded(.down)
        let next = (column + 1) % gridColumns
        func value(_ r: Int, _ c: Int) -> Double { Double(grid[r * gridColumns + c]) / 10 }
        let top = value(row, column) * (1 - fx) + value(row, next) * fx
        let bottom = value(row + 1, column) * (1 - fx) + value(row + 1, next) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// A height above mean sea level as a height above the ellipsoid.
    static func ellipsoidHeight(meanSeaLevel height: Double, latitude: Double, longitude: Double) -> Double {
        height + self.height(latitude: latitude, longitude: longitude)
    }
}
