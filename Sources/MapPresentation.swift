import RealityKit

/// Where the map is shown: the volume, or the immersive space. Each host
/// gives the placement its fixed geometry: the assumed eye, the map's centre
/// point and the shown square.
struct MapPresentation: Identifiable, Hashable {
    enum Host { case volume, immersive }

    let id: String
    /// The picker label.
    let name: String
    let host: Host
    /// The shown square's size relative to the volume's.
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

    /// Volume extents in metres (width, height, depth).
    static let volumeSize = SIMD3<Double>(1.0, 0.6, 1.0)

    static let volume = MapPresentation(
        id: "volume",
        name: "Volume",
        host: .volume,
        magnification: 1,
        groundPosition: [0, -0.25, 0],
        // In front of the volume, where the LOD camera assumes a viewer.
        viewerPosition: [0, 0.3, 0.85])

    /// The map on the origin plane around you. Its centre point is 5.6 m
    /// ahead, in a shown square 10 times the volume's, whose near edge is
    /// 0.6 m ahead, raised slightly so it doesn't fight the real floor.
    static let immersive = MapPresentation(
        id: "immersive",
        name: "Immersive",
        host: .immersive,
        magnification: 10,
        groundPosition: [0, 0.02, -5.6],
        // Where you stood when the immersive space opened.
        viewerPosition: [0, 1.6, 0])

    static let all: [MapPresentation] = [.volume, .immersive]

    /// The presentation with `id`. Saved view states from before the
    /// immersive modes became one say "immersive5x", or earlier "floor5x".
    static func withID(_ id: String) -> MapPresentation? {
        if id.hasPrefix("immersive") || id.hasPrefix("floor") { return .immersive }
        return all.first { $0.id == id }
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
                                  contentHalfWidth: Self.volumeSize.x / 2 * magnification))
    }
}
