import RealityKit

/// Where and how big the map is shown. Streaming (which tiles, at what
/// detail) is the same in every mode; a presentation only changes the display
/// scale and placement, so an immersive mode is the volume's map blown up.
///
/// Add or tweak entries in `all` to try other sizes and placements.
struct MapPresentation: Identifiable, Hashable {
    enum Host { case volume, immersive }

    let id: String
    /// The picker label: "Volume", or just the scale for immersive modes.
    let name: String
    let host: Host
    /// Display size relative to the volume: 5 makes the map five times wider
    /// and taller than it is in the volume.
    let magnification: Double
    /// Scene position of the focus point's ground, on the base plane. In the
    /// volume the origin is the volume's centre; in the immersive space it's
    /// the origin: the floor at the user's feet when the space opened, so the
    /// base plane is the origin plane (y = 0).
    let groundPosition: SIMD3<Float>
    /// Where the viewer's eyes are assumed to be, same space. Zoom and turns
    /// can pivot on the ground beneath it, so zooming reads as climbing or
    /// descending in place.
    let viewerPosition: SIMD3<Float>

    static let volume = MapPresentation(
        id: "volume",
        name: "Volume",
        host: .volume,
        magnification: 1,
        groundPosition: [0, -0.25, 0],
        // In front of the volume, where the LOD camera assumes a viewer.
        viewerPosition: [0, 0.3, 0.85])

    /// The map lying on the origin plane in front of you, its near edge `gap`
    /// metres ahead, raised slightly so it doesn't fight the real floor.
    static func immersive(_ magnification: Double, gap: Float = 0.6) -> MapPresentation {
        let halfWidth = Float(MapVolumeModel.volumeSize.x / 2 * magnification)
        return MapPresentation(
            id: "immersive\(Int(magnification))x",
            name: "\(Int(magnification))×",
            host: .immersive,
            magnification: magnification,
            groundPosition: [0, 0.02, -(halfWidth + gap)],
            // Where you stood when the immersive space opened.
            viewerPosition: [0, 1.6, 0])
    }

    static let all: [MapPresentation] = [.volume, .immersive(3), .immersive(5), .immersive(10)]

    /// The presentation with `id`. Saved view states from before the floor
    /// modes were renamed say "floor5x" for "immersive5x".
    static func withID(_ id: String) -> MapPresentation? {
        let current = id.hasPrefix("floor") ? "immersive" + id.dropFirst("floor".count) : id
        return all.first { $0.id == current }
    }

    /// The same placement as host geometry for the camera core: the viewer
    /// position is the design eye point, and the georeference point goes on
    /// the ground position when the map is level, or on the facing tilt's
    /// raised centre when looking straight down.
    var geometry: HostGeometry {
        let level = SIMD3<Double>(groundPosition)
        let downHeight = host == .volume ? 0 : Double(viewerPosition.y) - 0.3
        return .room(RoomGeometry(designEye: SIMD3<Double>(viewerPosition),
                                  placementLevel: level,
                                  placementDown: SIMD3(level.x, downHeight, level.z),
                                  contentHalfWidth: MapVolumeModel.volumeSize.x / 2 * magnification))
    }
}
