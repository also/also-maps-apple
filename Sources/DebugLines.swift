import RealityKit
import simd

/// Thin bars for debug wireframes: RealityKit has no line primitive.
enum DebugLines {
    typealias Segment = (SIMD3<Float>, SIMD3<Float>)

    /// A bar along each segment, `thickness` its half-width; nil if there's
    /// nothing to draw.
    static func mesh(_ segments: [Segment], thickness: Float) -> MeshResource? {
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
        guard !positions.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "lines")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// The 12 edges of a tile's bounding box, in the tile's own frame. The
    /// lines are a fixed fraction of the box's size: tiles are chosen to look
    /// about the same size, so the lines do too, at any zoom.
    static func box(_ bounds: CNTileBounds) -> MeshResource? {
        let axes = [bounds.halfAxisA, bounds.halfAxisB, bounds.halfAxisC]
        let corners = (0..<8).map { i -> SIMD3<Float> in
            var corner = bounds.centre
            for (bit, axis) in axes.enumerated() {
                corner += (i & (1 << bit) == 0 ? -1 : 1) * axis
            }
            return corner
        }
        var edges: [Segment] = []
        for bit in [1, 2, 4] {
            for i in 0..<8 where i & bit == 0 {
                edges.append((corners[i], corners[i | bit]))
            }
        }
        let size = axes.map(simd_length).max() ?? 0
        return mesh(edges, thickness: 0.006 * size)
    }

    static func material(red: Double, green: Double, blue: Double) -> UnlitMaterial {
        var material = UnlitMaterial(color: .init(red: red, green: green, blue: blue, alpha: 1))
        material.faceCulling = .none
        return material
    }
}
