import Foundation

/// Where the map's 3D tiles come from. Switching restarts streaming at the
/// same view.
enum TileSource: String, Codable, CaseIterable, Identifiable {
    /// Google Photorealistic 3D Tiles (Map Tiles API key).
    case googlePhotorealistic
    /// Cesium OSM Buildings via Cesium ion: untextured buildings worldwide,
    /// drawn lit. No terrain or imagery yet.
    case cesiumOSMBuildings
    /// Cesium World Terrain via Cesium ion, drawn lit in a flat colour until
    /// imagery overlays are supported (#8).
    case cesiumWorldTerrain

    var id: String { rawValue }

    var name: String {
        switch self {
        case .googlePhotorealistic: "Google Photorealistic"
        case .cesiumOSMBuildings: "Cesium OSM Buildings"
        case .cesiumWorldTerrain: "Cesium World Terrain"
        }
    }

    /// The Cesium ion asset, for ion sources.
    var ionAssetID: Int64? {
        switch self {
        case .googlePhotorealistic: nil
        case .cesiumOSMBuildings: 96188
        case .cesiumWorldTerrain: 1
        }
    }

    /// Smooth normals suit terrain; flat ones suit boxy buildings.
    var smoothNormals: Bool { self == .cesiumWorldTerrain }

    /// Colour for untextured content that brings none of its own (linear
    /// RGBA). Terrain tiles are bare geometry, so give them an earthy tone.
    var untexturedColor: SIMD4<Float>? {
        self == .cesiumWorldTerrain ? SIMD4(0.30, 0.33, 0.24, 1) : nil
    }
}
