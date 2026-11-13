import RealityKit

/// Where the map is shown: the volume, or the immersive space. Each host
/// gives the placement its fixed geometry: the assumed eye, the map's center
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
    /// volume the origin is the volume's center; in the immersive space it's
    /// the origin: the floor at the user's feet when the space opened, so the
    /// base plane is the origin plane (y = 0).
    let groundPosition: SIMD3<Float>
    /// Where the viewer's eyes are assumed to be, same space. Zoom and turns
    /// can pivot on the ground beneath it, so zooming reads as climbing or
    /// descending in place.
    let viewerPosition: SIMD3<Float>

    /// Volume extents in meters (width, height, depth).
    static let volumeSize = SIMD3<Double>(1.0, 0.6, 1.0)

    static let volume = MapPresentation(
        id: "volume",
        name: "Volume",
        host: .volume,
        magnification: 1,
        groundPosition: [0, -0.25, 0],
        // In front of the volume, where the LOD camera assumes a viewer.
        viewerPosition: [0, 0.3, 0.85])

    /// The map on the origin plane around you, raised slightly so it doesn't
    /// fight the real floor. The ground position is left from the old floor
    /// modes' square of map, 5.6 m ahead: it still sets the base plane's
    /// height and where the attribution goes, but not the view center
    /// (`immersiveRestingDip`).
    static let immersive = MapPresentation(
        id: "immersive",
        name: "Immersive",
        host: .immersive,
        magnification: 10,
        groundPosition: [0, 0.02, -5.6],
        // Where you stood when the immersive space opened.
        viewerPosition: [0, 1.6, 0])

    /// How far below level the immersive space's view center is while the
    /// map is level: about where a relaxed gaze rests. The view center is
    /// then about 3.7 × the height above ground ahead, whatever the measured
    /// eye height. (The volume's is at its box's ground center instead.)
    static let immersiveRestingDip = 15 * Double.pi / 180

    static let all: [MapPresentation] = [.volume, .immersive]

    /// The area of interest this host streams: the shown region in the
    /// volume, and in the immersive space everything visible, out to the
    /// horizon, unless `settings` limits its reach.
    func areaPolicy(_ settings: StreamingSettings) -> AOIPolicy {
        switch host {
        case .volume: .georeference(regionMultiplier: 1)
        case .immersive: .horizon(limitPerAltitude: settings.limitsImmersiveReach ? settings.immersiveReach : nil)
        }
    }

    /// The presentation with `id`. Saved view states from before the
    /// immersive modes became one say "immersive5x", or earlier "floor5x".
    static func withID(_ id: String) -> MapPresentation? {
        if id.hasPrefix("immersive") || id.hasPrefix("floor") { return .immersive }
        return all.first { $0.id == id }
    }

    /// The same placement as host geometry for the camera core: the viewer
    /// position is the design eye point, and the view center is on the
    /// ground position while the map is level.
    var geometry: HostGeometry {
        let level = SIMD3<Double>(groundPosition)
        let eye = SIMD3<Double>(viewerPosition)
        // The volume tilts until the ground below faces you at the box's
        // center, so the view center, which follows it, stays in the box.
        // The immersive space tilts a quarter turn, until the ground below is
        // straight ahead.
        let boxCenter = SIMD3(level.x, 0, level.z)
        return .room(RoomGeometry(designEye: eye,
                                  placementLevel: level,
                                  contentHalfWidth: Self.volumeSize.x / 2 * magnification,
                                  fullTilt: host == .volume ? RoomGeometry.tiltFacing(boxCenter, from: eye) : .pi / 2,
                                  restingDip: host == .volume ? nil : Self.immersiveRestingDip))
    }
}
