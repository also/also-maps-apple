import RealityKit

/// Where and how big the map is shown. Streaming (which tiles, at what
/// detail) is the same in every mode; a presentation only changes the display
/// scale and placement, so a floor mode is the volume's map blown up.
///
/// Add or tweak entries in `all` to try other sizes and placements.
struct MapPresentation: Identifiable, Hashable {
    enum Host { case volume, immersive }

    let id: String
    let name: String
    let host: Host
    /// Display size relative to the volume: 5 makes the map five times wider
    /// and taller than it is in the volume.
    let magnification: Double
    /// Scene position of the focus point's ground. In the volume the origin is
    /// the volume's centre; in the immersive space it's the floor at the
    /// user's feet when the space opened.
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

    /// The map lying on the floor in front of you, its near edge `gap` metres
    /// ahead, raised slightly so it doesn't fight the real floor.
    static func floor(_ magnification: Double, gap: Float = 0.6) -> MapPresentation {
        let halfWidth = Float(MapVolumeModel.volumeSize.x / 2 * magnification)
        return MapPresentation(
            id: "floor\(Int(magnification))x",
            name: "Floor \(Int(magnification))×",
            host: .immersive,
            magnification: magnification,
            groundPosition: [0, 0.02, -(halfWidth + gap)],
            // Where you stood when the immersive space opened.
            viewerPosition: [0, 1.6, 0])
    }

    static let all: [MapPresentation] = [.volume, .floor(3), .floor(5), .floor(10)]
}
