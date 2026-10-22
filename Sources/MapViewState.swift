import Foundation

/// Everything needed to put the view back exactly as it was: where the map
/// is, how it's shown, Fly's pose and the settings that shape navigation.
/// Copied as JSON from Tuning; restored from the clipboard or, at launch,
/// from MAPVOLUME_STATE.
struct MapViewState: Codable {
    var latitude: Double
    var longitude: Double
    /// Anchored ground height at the focus, metres above the ellipsoid.
    var focusHeight: Double
    /// View half-width, metres.
    var radius: Double
    var headingDegrees: Double
    /// MapPresentation.id, e.g. "floor5x".
    var presentation: String
    var flying: Bool
    var flyScale: Float
    var flyYawDegrees: Float
    var flyTranslation: [Float]
    var settings: StreamingSettings

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func parse(_ text: String) -> MapViewState? {
        try? JSONDecoder().decode(MapViewState.self, from: Data(text.utf8))
    }
}
