import Foundation
import simd

/// Content bounds in the same tile-local axes as the uploaded vertices.
/// Computed once, before the CPU positions are discarded.
struct MetalBounds {
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>

    init(minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        self.minimum = minimum
        self.maximum = maximum
    }

    init?(positions: Data) {
        guard !positions.isEmpty, positions.count.isMultiple(of: MemoryLayout<SIMD4<Float>>.stride) else { return nil }
        let bounds: MetalBounds? = positions.withUnsafeBytes { bytes in
            var minimum = SIMD3<Float>(repeating: .infinity)
            var maximum = SIMD3<Float>(repeating: -.infinity)
            for offset in stride(from: 0, to: bytes.count, by: MemoryLayout<SIMD4<Float>>.stride) {
                // Data isn't guaranteed to be aligned to SIMD4's alignment.
                let vertex = bytes.loadUnaligned(fromByteOffset: offset, as: SIMD4<Float>.self)
                let point = SIMD3(vertex.x, vertex.y, vertex.z)
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            }
            return MetalBounds(minimum: minimum, maximum: maximum)
        }
        guard let bounds else { return nil }
        self = bounds
    }

    func union(_ other: MetalBounds) -> MetalBounds {
        MetalBounds(minimum: simd_min(minimum, other.minimum), maximum: simd_max(maximum, other.maximum))
    }
}

/// Conservative box/frustum test using Metal's homogeneous clip volume:
/// -w <= x,y <= w and 0 <= z <= w. Works with reverse Z, asymmetric eye
/// projections, and arbitrary tile/root transforms, without dividing by w.
struct MetalFrustum {
    private let left, right, bottom, top, lowZ, highZ: SIMD4<Float>

    init(clipFromLocal matrix: simd_float4x4) {
        let rows = matrix.transpose
        let x = rows.columns.0, y = rows.columns.1, z = rows.columns.2, w = rows.columns.3
        left = w + x
        right = w - x
        bottom = w + y
        top = w - y
        lowZ = z
        highZ = w - z
    }

    func intersects(_ bounds: MetalBounds?) -> Bool {
        // Unknown bounds must never hide content.
        guard let bounds else { return true }
        return !outside(bounds, plane: left) && !outside(bounds, plane: right)
            && !outside(bounds, plane: bottom) && !outside(bounds, plane: top)
            && !outside(bounds, plane: lowZ) && !outside(bounds, plane: highZ)
    }

    private func outside(_ bounds: MetalBounds, plane: SIMD4<Float>) -> Bool {
        // If even the box's furthest point is outside one plane, the entire
        // box is outside. A box crossing the eye/near plane stays drawable.
        let normal = SIMD3(plane.x, plane.y, plane.z)
        let support = SIMD3(plane.x >= 0 ? bounds.maximum.x : bounds.minimum.x,
                            plane.y >= 0 ? bounds.maximum.y : bounds.minimum.y,
                            plane.z >= 0 ? bounds.maximum.z : bounds.minimum.z)
        let distance = simd_dot(normal, support) + plane.w
        // Allow for Float cancellation at a boundary, proportional to the
        // terms being added. Degenerate/infinite-far planes keep content.
        let magnitude = simd_dot(simd_abs(normal), simd_max(simd_abs(bounds.minimum), simd_abs(bounds.maximum)))
            + abs(plane.w)
        let tolerance = 32 * Float.ulpOfOne * max(1, magnitude)
        return distance < -tolerance
    }
}

enum MetalProjection {
    /// Off-axis perspective looking down -z, reverse Z. Tangents are
    /// (left, right, top, bottom); compositor views supply their own matrix.
    static func perspective(tangents: SIMD4<Float>, near: Float, far: Float) -> simd_float4x4 {
        let left = -tangents[0], right = tangents[1], top = tangents[2], bottom = -tangents[3]
        let width = right - left, height = top - bottom
        return simd_float4x4(columns: (
            [2 / width, 0, 0, 0],
            [0, 2 / height, 0, 0],
            [(right + left) / width, (top + bottom) / height, near / (far - near), -1],
            [0, 0, near * far / (far - near), 0]
        ))
    }
}
