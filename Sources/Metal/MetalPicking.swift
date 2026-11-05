import Foundation
import simd

/// A half-line in the renderer's Float scene space. (`Ray` is the Double
/// ECEF one used by navigation.) `direction` needn't be unit length, and
/// distances along the ray are in units of it; `MetalTileRenderer.pick`
/// normalises first so its distances are metres.
struct MetalRay: Equatable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>

    func point(at t: Float) -> SIMD3<Float> { origin + direction * t }

    /// The same ray in another frame. Translation applies to the origin only;
    /// the direction isn't renormalised, so `t` means the same in both frames.
    func transformed(by matrix: simd_float4x4) -> MetalRay {
        let origin = matrix * SIMD4(origin, 1)
        let direction = matrix * SIMD4(direction, 0)
        return MetalRay(origin: SIMD3(origin.x, origin.y, origin.z),
                        direction: SIMD3(direction.x, direction.y, direction.z))
    }
}

/// Ray-casting maths with no Metal in it, so the core tests can cover it.
/// `MetalTileRenderer.pick` composes these over the drawn tiles.
enum MetalPicking {
    /// The ray through a point of a perspective view (points, y down) as
    /// drawn by `MetalProjection.perspective`: camera looks down its −z with
    /// +y up. `halfHeightTangent` is tan(vertical fov / 2) and
    /// `sceneFromCamera` is the camera's pose in the scene.
    static func ray(throughPoint point: SIMD2<Double>, viewSize: SIMD2<Double>, halfHeightTangent: Double,
                    sceneFromCamera: simd_float4x4) -> MetalRay? {
        guard viewSize.x > 0, viewSize.y > 0 else { return nil }
        let aspect = viewSize.x / viewSize.y
        let x = (2 * point.x / viewSize.x - 1) * halfHeightTangent * aspect
        let y = (1 - 2 * point.y / viewSize.y) * halfHeightTangent
        let local = MetalRay(origin: .zero, direction: SIMD3(Float(x), Float(y), -1))
        return local.transformed(by: sceneFromCamera)
    }

    /// Where the ray enters the box (0 if it starts inside), or nil if it
    /// misses or the box is wholly behind it. Slab method; a direction
    /// component of zero is a ray parallel to that pair of faces.
    static func entryDistance(of ray: MetalRay, bounds: MetalBounds) -> Float? {
        var near: Float = 0
        var far = Float.infinity
        for axis in 0..<3 {
            let origin = ray.origin[axis], direction = ray.direction[axis]
            let low = bounds.minimum[axis], high = bounds.maximum[axis]
            if direction == 0 {
                if origin < low || origin > high { return nil }
                continue
            }
            var t0 = (low - origin) / direction
            var t1 = (high - origin) / direction
            if t0 > t1 { swap(&t0, &t1) }
            near = max(near, t0)
            far = min(far, t1)
            if near > far { return nil }
        }
        return near
    }

    /// Möller–Trumbore, double-sided (the renderer doesn't cull). Returns the
    /// distance along the ray, > 0, or nil for a miss or a degenerate
    /// triangle. Edges and corners count as hits.
    static func distance(of ray: MetalRay, toTriangle a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let edge1 = b - a, edge2 = c - a
        let p = simd_cross(ray.direction, edge2)
        let determinant = simd_dot(edge1, p)
        guard abs(determinant) > 1e-12 else { return nil }
        let inverse = 1 / determinant
        let s = ray.origin - a
        let u = simd_dot(s, p) * inverse
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, edge1)
        let v = simd_dot(ray.direction, q) * inverse
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(edge2, q) * inverse
        return t > 0 && t.isFinite ? t : nil
    }

    /// The nearest triangle hit in an indexed mesh, no farther than
    /// `maxDistance`. `positions` is the renderer's vertex layout (SIMD4<Float>
    /// per vertex, w ignored) and `indices` UInt32 triples; both are read in
    /// place (unaligned loads), so an MTLBuffer's `contents()` can be passed
    /// straight in. Triangles with an out-of-range index or a non-finite
    /// corner are skipped.
    static func nearestHit(of ray: MetalRay, positions: UnsafeRawBufferPointer, indices: UnsafeRawBufferPointer,
                           maxDistance: Float = .infinity) -> (triangle: Int, distance: Float)? {
        let vertexCount = positions.count / MemoryLayout<SIMD4<Float>>.stride
        let triangleCount = indices.count / (3 * MemoryLayout<UInt32>.stride)
        func vertex(_ index: UInt32) -> SIMD3<Float>? {
            guard Int(index) < vertexCount else { return nil }
            let v = positions.loadUnaligned(fromByteOffset: Int(index) * MemoryLayout<SIMD4<Float>>.stride,
                                            as: SIMD4<Float>.self)
            return SIMD3(v.x, v.y, v.z)
        }
        var best: (triangle: Int, distance: Float)?
        var limit = maxDistance
        for triangle in 0..<triangleCount {
            let base = triangle * 3 * MemoryLayout<UInt32>.stride
            let i0 = indices.loadUnaligned(fromByteOffset: base, as: UInt32.self)
            let i1 = indices.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self)
            let i2 = indices.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self)
            guard let a = vertex(i0), let b = vertex(i1), let c = vertex(i2),
                  let t = distance(of: ray, toTriangle: a, b, c), t <= limit else { continue }
            best = (triangle, t)
            limit = t
        }
        return best
    }
}
