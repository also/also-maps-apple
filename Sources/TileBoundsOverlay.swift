import RealityKit
import UIKit

/// Debug wireframes for streaming, in the tiles' frame (a child of
/// `tilesRoot`) so they move with the tiles: the area-of-interest square
/// (yellow) and the LOD camera's view (pink, its view direction white).
/// Each line is a unit bar placed by its transform, so following the
/// streaming inputs every frame never rebuilds a mesh. Each tile's own box
/// is drawn by TileStreaming.
@MainActor
final class TileBoundsOverlay {
    let root = Entity()
    private let squareBars: [ModelEntity]
    private let viewBars: [ModelEntity]
    private let directionBar: ModelEntity

    init() {
        let bar = MeshResource.generateBox(size: 1)
        func bars(_ count: Int, _ color: UIColor) -> [ModelEntity] {
            var material = UnlitMaterial(color: color)
            material.faceCulling = .none
            return (0..<count).map { _ in ModelEntity(mesh: bar, materials: [material]) }
        }
        squareBars = bars(4, .systemYellow)
        viewBars = bars(12, .systemPink)
        directionBar = bars(1, .white)[0]
        for entity in squareBars + viewBars + [directionBar] {
            root.addChild(entity)
        }
        root.isEnabled = false
    }

    var isEnabled: Bool {
        get { root.isEnabled }
        set { root.isEnabled = newValue }
    }

    /// `scale` is the tiles' frame's scale into the map frame; `thickness`
    /// is the lines' half-width in the map frame.
    func update(inputs: StreamingInputs, scale: Float, thickness: Float) {
        guard root.isEnabled, scale > 0 else { return }
        let width = thickness / scale

        // The square the bridge actually excludes by: axis-aligned in east
        // and north, grown to enclose the turned region.
        let r = Float(inputs.streamingRadius * (abs(sin(inputs.regionHeading)) + abs(cos(inputs.regionHeading))))
        let square: [SIMD3<Float>] = [[-r, 0, -r], [r, 0, -r], [r, 0, r], [-r, 0, r]]
        for i in 0..<4 {
            Self.place(squareBars[i], square[i], square[(i + 1) % 4], width * 2)
        }

        // The LOD camera's view, out to twice the streaming radius. It starts
        // a little way out: the camera is usually at the viewer's eyes, where
        // lines leaving it would be seen end-on.
        let lod = inputs.lod
        let position = SIMD3<Float>(lod.position)
        let direction = SIMD3<Float>(simd_normalize(lod.direction))
        let up = SIMD3<Float>(simd_normalize(lod.up))
        let right = simd_normalize(simd_cross(direction, up))
        let length = Float(2 * inputs.streamingRadius)
        let halfHeight = Float(tan(lod.fieldOfView / 2))
        let halfWidth = halfHeight * Float(lod.aspect)
        func rectangle(_ distance: Float) -> [SIMD3<Float>] {
            let signs: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
            return signs.map { x, y in
                let offset: SIMD3<Float> = x * halfWidth * right + y * halfHeight * up
                return position + distance * (direction + offset)
            }
        }
        let near = rectangle(0.03 * length), far = rectangle(length)
        for i in 0..<4 {
            let next = (i + 1) % 4
            Self.place(viewBars[3 * i], near[i], far[i], width)
            Self.place(viewBars[3 * i + 1], near[i], near[next], width)
            Self.place(viewBars[3 * i + 2], far[i], far[next], width)
        }
        Self.place(directionBar, position + 0.03 * length * direction, position + length * direction, width)
    }

    /// Stretches a unit bar from `a` to `b`, `width` its half-width.
    private static func place(_ bar: ModelEntity, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ width: Float) {
        let along = b - a
        let length = simd_length(along)
        guard length > 1e-6, length.isFinite, width.isFinite else {
            bar.isEnabled = false
            return
        }
        bar.isEnabled = true
        bar.transform = Transform(scale: [2 * width, 2 * width, length],
                                  rotation: simd_quatf(from: [0, 0, 1], to: along / length),
                                  translation: (a + b) / 2)
    }
}
