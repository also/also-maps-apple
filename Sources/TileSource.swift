import Foundation

/// Where the map's 3D tiles come from. Switching restarts streaming at the
/// same view.
enum TileSource: String, Codable, CaseIterable, Identifiable {
    /// Google Photorealistic 3D Tiles (Map Tiles API key).
    case googlePhotorealistic
    /// Cesium OSM Buildings via Cesium ion: untextured buildings worldwide,
    /// drawn lit. No terrain or imagery.
    case cesiumOSMBuildings
    /// Cesium World Terrain via Cesium ion, drawn lit in a flat colour.
    case cesiumWorldTerrain
    /// Cesium World Terrain draped with Bing Maps Aerial imagery, with Cesium
    /// OSM Buildings on it, all via Cesium ion.
    case cesiumTerrainImageryBuildings

    var id: String { rawValue }

    var name: String {
        switch self {
        case .googlePhotorealistic: "Google Photorealistic"
        case .cesiumOSMBuildings: "Cesium OSM Buildings"
        case .cesiumWorldTerrain: "Cesium World Terrain"
        case .cesiumTerrainImageryBuildings: "Cesium Terrain, Imagery and Buildings"
        }
    }

    /// One Cesium ion tileset, optionally draped with ion imagery.
    struct IonLayer {
        var assetID: Int64
        var imageryAssetID: Int64?
        /// Smooth normals suit terrain; flat ones suit boxy buildings.
        var smoothNormals: Bool
    }

    private static let worldTerrain: Int64 = 1
    private static let bingMapsAerial: Int64 = 2
    private static let osmBuildings: Int64 = 96188

    /// The ion tilesets to stream together, ground first (height samples
    /// come from it); nil for sources that aren't on ion.
    var ionLayers: [IonLayer]? {
        switch self {
        case .googlePhotorealistic:
            nil
        case .cesiumOSMBuildings:
            [IonLayer(assetID: Self.osmBuildings, smoothNormals: false)]
        case .cesiumWorldTerrain:
            [IonLayer(assetID: Self.worldTerrain, smoothNormals: true)]
        case .cesiumTerrainImageryBuildings:
            [IonLayer(assetID: Self.worldTerrain, imageryAssetID: Self.bingMapsAerial, smoothNormals: true),
             IonLayer(assetID: Self.osmBuildings, smoothNormals: false)]
        }
    }

    /// Colour for untextured content that brings none of its own (linear
    /// RGBA). Terrain tiles are bare geometry, so give them an earthy tone.
    var untexturedColor: SIMD4<Float>? {
        self == .cesiumWorldTerrain ? SIMD4(0.30, 0.33, 0.24, 1) : nil
    }
}
