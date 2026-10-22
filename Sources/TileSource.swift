import Foundation

/// Where the map's 3D tiles come from. Switching restarts streaming at the
/// same view.
enum TileSource: String, Codable, CaseIterable, Identifiable {
    /// Google Photorealistic 3D Tiles (Map Tiles API key).
    case googlePhotorealistic
    /// Cesium OSM Buildings via Cesium ion: untextured buildings worldwide,
    /// drawn lit. No terrain or imagery yet.
    case cesiumOSMBuildings

    var id: String { rawValue }

    var name: String {
        switch self {
        case .googlePhotorealistic: "Google Photorealistic"
        case .cesiumOSMBuildings: "Cesium OSM Buildings"
        }
    }

    /// The Cesium ion asset, for ion sources.
    var ionAssetID: Int64? {
        switch self {
        case .googlePhotorealistic: nil
        case .cesiumOSMBuildings: 96188
        }
    }
}
