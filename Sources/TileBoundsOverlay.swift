import RealityKit
import UIKit

/// Debug wireframes in the map frame: each drawn tile's bounding box (cyan
/// inside the LOD camera's view, orange outside it), the area of interest's
/// square (yellow) and the LOD camera's view (magenta, its view direction
/// white). Rebuilt a few times a second while enabled.
@MainActor
final class TileBoundsOverlay {
    typealias Segment = (SIMD3<Float>, SIMD3<Float>)

    let root = Entity()
    private let insideView = TileBoundsOverlay.lines(.systemCyan)
    private let outsideView = TileBoundsOverlay.lines(.systemOrange)
    private let areaOfInterest = TileBoundsOverlay.lines(.systemYellow)
    private let lodView = TileBoundsOverlay.lines(.systemPink)
    private let lodDirection = TileBoundsOverlay.lines(.white)
    private var sinceRebuild: Float = .infinity

    init() {
        root.isEnabled = false
        for entity in [insideView, outsideView, areaOfInterest, lodView, lodDirection] {
            root.addChild(entity)
        }
    }

    var isEnabled: Bool {
        get { root.isEnabled }
        set {
            root.isEnabled = newValue
            sinceRebuild = .infinity
        }
    }

    /// `tilesFrame` maps the tiles' frame (the streaming anchor's) into the
    /// map frame; `thickness` is the lines' half-width in the map frame.
    func update(deltaTime: Float, bounds: [CNTileBounds], inputs: StreamingInputs,
                tilesFrame: simd_float4x4, thickness: Float) {
        guard root.isEnabled else { return }
        sinceRebuild += deltaTime
        guard sinceRebuild >= 0.2 else { return }
        sinceRebuild = 0

        func map(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let q = tilesFrame * SIMD4(p, 1)
            return SIMD3(q.x, q.y, q.z)
        }

        var inside: [Segment] = [], outside: [Segment] = []
        for box in bounds {
            let corners = (0..<8).map { i -> SIMD3<Float> in
                let a: Float = i & 1 == 0 ? -1 : 1
                let b: Float = i & 2 == 0 ? -1 : 1
                let c: Float = i & 4 == 0 ? -1 : 1
                return map(box.centre + a * box.halfAxisA + b * box.halfAxisB + c * box.halfAxisC)
            }
            // The 12 edges join corners that differ in one axis.
            for bit in [1, 2, 4] {
                for i in 0..<8 where i & bit == 0 {
                    if box.inView {
                        inside.append((corners[i], corners[i | bit]))
                    } else {
                        outside.append((corners[i], corners[i | bit]))
                    }
                }
            }
        }

        // The square the bridge actually excludes by: axis-aligned in east
        // and north, grown to enclose the turned region.
        let r = Float(inputs.streamingRadius * (abs(sin(inputs.regionHeading)) + abs(cos(inputs.regionHeading))))
        let square = [SIMD3<Float>(-r, 0, -r), [r, 0, -r], [r, 0, r], [-r, 0, r]].map(map)
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
                return map(position + distance * (direction + offset))
            }
        }
        let near = rectangle(0.03 * length), far = rectangle(length)
        var viewEdges: [Segment] = []
        for i in 0..<4 {
            let next = (i + 1) % 4
            viewEdges += [(near[i], far[i]), (near[i], near[next]), (far[i], far[next])]
        }

        Self.set(insideView, inside, thickness)
        Self.set(outsideView, outside, thickness)
        Self.set(areaOfInterest, squareEdges, thickness * 2)
        Self.set(lodView, viewEdges, thickness)
        Self.set(lodDirection, [(map(position + 0.03 * length * direction), map(position + length * direction))],
                 thickness)
    }

    private static func lines(_ color: UIColor) -> ModelEntity {
        var material = UnlitMaterial(color: color)
        material.faceCulling = .none
        let entity = ModelEntity()
        entity.model = ModelComponent(mesh: .generateBox(size: 0), materials: [material])
        entity.isEnabled = false
        return entity
    }

    /// Replaces `entity`'s mesh with a thin bar along each segment.
    private static func set(_ entity: ModelEntity, _ segments: [Segment], _ thickness: Float) {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(segments.count * 8)
        indices.reserveCapacity(segments.count * 24)
        for (a, b) in segments {
            let along = b - a
            let length = simd_length(along)
            guard length > 1e-6, length.isFinite else { continue }
            let n = along / length
            let helper: SIMD3<Float> = abs(n.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
            let u = simd_normalize(simd_cross(n, helper)) * thickness
            let v = simd_cross(n, u)
            let base = UInt32(positions.count)
            for end in [a, b] {
                positions += [end + u, end + v, end - u, end - v]
            }
            // Four side faces, two triangles each.
            for side in UInt32(0)..<4 {
                let next = (side + 1) % 4
                indices += [base + side, base + next, base + 4 + side,
                            base + next, base + 4 + next, base + 4 + side]
            }
        }
        guard !positions.isEmpty else {
            entity.isEnabled = false
            return
        }
        var descriptor = MeshDescriptor(name: "lines")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return }
        entity.model?.mesh = mesh
        entity.isEnabled = true
    }
}
