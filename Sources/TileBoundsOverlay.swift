import RealityKit
import UIKit

/// Debug wireframes for streaming, in the tiles' frame (a child of
/// `tilesRoot`) so they move with the tiles: the area-of-interest square
/// (yellow) and the LOD camera's view (pink, its view direction white).
/// Rebuilt only when the streaming inputs change or the map's scale drifts.
/// Each tile's own box is drawn by TileStreaming.
@MainActor
final class TileBoundsOverlay {
    let root = Entity()
    private let areaOfInterest = TileBoundsOverlay.lines(.systemYellow)
    private let lodView = TileBoundsOverlay.lines(.systemPink)
    private let lodDirection = TileBoundsOverlay.lines(.white)
    private var built: (inputs: StreamingInputs, scale: Float)?

    init() {
        root.isEnabled = false
        for entity in [areaOfInterest, lodView, lodDirection] {
            root.addChild(entity)
        }
    }

    var isEnabled: Bool {
        get { root.isEnabled }
        set {
            root.isEnabled = newValue
            built = nil
        }
    }

    /// `scale` is the tiles' frame's scale into the map frame; `thickness`
    /// is the lines' half-width in the map frame.
    func update(inputs: StreamingInputs, scale: Float, thickness: Float) {
        guard root.isEnabled, scale > 0 else { return }
        if let built, built.inputs == inputs, abs(scale / built.scale - 1) < 0.05 { return }
        built = (inputs, scale)
        let width = thickness / scale

        // The square the bridge actually excludes by: axis-aligned in east
        // and north, grown to enclose the turned region.
        let r = Float(inputs.streamingRadius * (abs(sin(inputs.regionHeading)) + abs(cos(inputs.regionHeading))))
        let square: [SIMD3<Float>] = [[-r, 0, -r], [r, 0, -r], [r, 0, r], [-r, 0, r]]
        let squareEdges = (0..<4).map { (square[$0], square[($0 + 1) % 4]) }

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
        var viewEdges: [DebugLines.Segment] = []
        for i in 0..<4 {
            let next = (i + 1) % 4
            viewEdges += [(near[i], far[i]), (near[i], near[next]), (far[i], far[next])]
        }

        Self.set(areaOfInterest, squareEdges, width * 2)
        Self.set(lodView, viewEdges, width)
        Self.set(lodDirection, [(position + 0.03 * length * direction, position + length * direction)], width)
    }

    private static func lines(_ color: UIColor) -> ModelEntity {
        var material = UnlitMaterial(color: color)
        material.faceCulling = .none
        let entity = ModelEntity()
        entity.model = ModelComponent(mesh: .generateBox(size: 0), materials: [material])
        entity.isEnabled = false
        return entity
    }

    private static func set(_ entity: ModelEntity, _ segments: [DebugLines.Segment], _ thickness: Float) {
        guard let mesh = DebugLines.mesh(segments, thickness: thickness) else {
            entity.isEnabled = false
            return
        }
        entity.model?.mesh = mesh
        entity.isEnabled = true
    }
}
