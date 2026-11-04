import Foundation
import simd
import Testing

struct MetalVisibilityTests {
    private var projection: simd_float4x4 {
        MetalProjection.perspective(tangents: [1, 1, 1, 1], near: 1, far: 100)
    }

    private func box(_ center: SIMD3<Float>, _ extent: SIMD3<Float> = [0.1, 0.1, 0.1]) -> MetalBounds {
        MetalBounds(minimum: center - extent, maximum: center + extent)
    }

    @Test
    func rejectsGeometryWhollyBehindTheEye() {
        let frustum = MetalFrustum(clipFromLocal: projection)
        #expect(frustum.intersects(box([0, 0, -10])))
        #expect(!frustum.intersects(box([0, 0, 10], [5, 5, 5])))
    }

    @Test(arguments: [SIMD3<Float>(-20, 0, -10), [20, 0, -10], [0, -20, -10],
                      [0, 20, -10], [0, 0, -0.5], [0, 0, -110]])
    func rejectsEveryClipPlane(center: SIMD3<Float>) {
        #expect(!MetalFrustum(clipFromLocal: projection).intersects(box(center)))
    }

    @Test(arguments: [SIMD3<Float>(-10, 0, -10), [10, 0, -10], [0, -10, -10],
                      [0, 10, -10], [0, 0, -1], [0, 0, -100]])
    func keepsGeometryTouchingOrCrossingAClipPlane(center: SIMD3<Float>) {
        let frustum = MetalFrustum(clipFromLocal: projection)
        #expect(frustum.intersects(box(center)))
        #expect(frustum.intersects(box(center, .zero)))
    }

    @Test
    func keepsBoxesContainingTheEyeOrWholeFrustum() {
        let frustum = MetalFrustum(clipFromLocal: projection)
        #expect(frustum.intersects(box(.zero, [2, 2, 2])))
        // No box corner is inside the frustum, but visible geometry can be.
        #expect(frustum.intersects(box([0, 0, -50], [200, 200, 200])))
        #expect(frustum.intersects(nil))
    }

    @Test
    func usesMetalZeroToWDepthInsteadOfOpenGLMinusWToW() {
        let frustum = MetalFrustum(clipFromLocal: matrix_identity_float4x4)
        #expect(!frustum.intersects(box([0, 0, -0.5])))
        #expect(frustum.intersects(box([0, 0, 0.5])))
    }

    @Test
    func usesTheActualAsymmetricEyeProjection() {
        let asymmetric = MetalProjection.perspective(tangents: [0.25, 1.5, 1.2, 0.4], near: 1, far: 100)
        let frustum = MetalFrustum(clipFromLocal: asymmetric)
        #expect(frustum.intersects(box([10, 0, -10])))
        #expect(!frustum.intersects(box([-5, 0, -10])))
        #expect(frustum.intersects(box([0, 10, -10])))
        #expect(!frustum.intersects(box([0, -6, -10])))
    }

    @Test
    func stereoTestsEachEyeIndependently() {
        var fromLeftEye = matrix_identity_float4x4
        fromLeftEye.columns.3.x = 0.1
        var fromRightEye = matrix_identity_float4x4
        fromRightEye.columns.3.x = -0.1
        let edge = box([10.05, 0, -10], [0.001, 0.001, 0.001])
        #expect(!MetalFrustum(clipFromLocal: projection * fromLeftEye).intersects(edge))
        #expect(MetalFrustum(clipFromLocal: projection * fromRightEye).intersects(edge))
    }

    @Test
    func transformsBoundsWithTheSamePlacementAsVertices() {
        var placement = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        placement.columns.0 *= 0.01
        placement.columns.1 *= 0.02
        placement.columns.2 *= -0.03
        placement.columns.3 = [0, 0, -10, 1]
        #expect(MetalFrustum(clipFromLocal: projection * placement).intersects(box(.zero)))
        placement.columns.3.z = 10
        #expect(!MetalFrustum(clipFromLocal: projection * placement).intersects(box(.zero)))
    }

    @Test
    func toleratesAnInfiniteFarProjection() {
        // Reverse-Z infinite far: clip z = near and clip w = -view z.
        let infinite = simd_float4x4(columns: ([1, 0, 0, 0], [0, 1, 0, 0],
                                              [0, 0, 0, -1], [0, 0, 1, 0]))
        let frustum = MetalFrustum(clipFromLocal: infinite)
        #expect(frustum.intersects(box([0, 0, -1e9], [1e4, 1e4, 1e4])))
        #expect(!frustum.intersects(box([0, 0, 10])))
    }

    @Test
    func boundsComeFromAllPackedVerticesAndIgnorePadding() throws {
        let vertices: [SIMD4<Float>] = [[8, -2, 4, .nan], [-7, 9, 1, 0], [0, 3, -5, 1]]
        let data = vertices.withUnsafeBytes { Data($0) }
        let bounds = try #require(MetalBounds(positions: data))
        #expect(bounds.minimum == [-7, -2, -5])
        #expect(bounds.maximum == [8, 9, 4])
        let union = bounds.union(box([20, 0, 0], [1, 1, 1]))
        #expect(union.minimum == [-7, -2, -5])
        #expect(union.maximum == [21, 9, 4])
        #expect(MetalBounds(positions: Data()) == nil)
        #expect(MetalBounds(positions: Data([1, 2, 3])) == nil)
        let invalid = [SIMD4<Float>(.nan, 0, 0, 0)].withUnsafeBytes { Data($0) }
        #expect(MetalBounds(positions: invalid) == nil)
    }

    @Test
    func neverRejectsABoxWithAnInsideSampleAfterArbitraryTransforms() {
        // Independent oracle: transform 27 sample points and check the raw
        // homogeneous clip inequalities, without extracted frustum planes.
        var seed: UInt64 = 0x5eed
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1
            return Float(seed >> 40) / Float(1 << 24)
        }
        for _ in 0..<2_000 {
            var transform = simd_float4x4(simd_quatf(angle: random() * 6, axis: simd_normalize([1, 2, 3])))
            transform.columns.0 *= 0.01 + 3 * random()
            transform.columns.1 *= 0.01 + 3 * random()
            transform.columns.2 *= -0.01 - 3 * random()
            transform.columns.3 = [random() * 40 - 20, random() * 40 - 20, random() * 120 - 105, 1]
            let matrix = projection * transform
            let center = SIMD3<Float>(random() * 10 - 5, random() * 10 - 5, random() * 10 - 5)
            let extent = SIMD3<Float>(random() * 5, random() * 5, random() * 5)
            let bounds = box(center, extent)
            var hasInsideSample = false
            for x: Float in [-1, 0, 1] {
                for y: Float in [-1, 0, 1] {
                    for z: Float in [-1, 0, 1] {
                        let p = center + extent * SIMD3(x, y, z)
                        let clip = matrix * SIMD4(p, 1)
                        hasInsideSample = hasInsideSample || (abs(clip.x) <= clip.w && abs(clip.y) <= clip.w
                            && clip.z >= 0 && clip.z <= clip.w)
                    }
                }
            }
            #expect(!hasInsideSample || MetalFrustum(clipFromLocal: matrix).intersects(bounds))
        }
    }
}
