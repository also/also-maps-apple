import Foundation
import simd
import Testing

struct MetalPickingTests {
    private func box(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> MetalBounds {
        MetalBounds(minimum: low, maximum: high)
    }

    private let unitBox = MetalBounds(minimum: [-1, -1, -1], maximum: [1, 1, 1])

    // MARK: Ray and box

    @Test
    func rayHitsBoxAtEntryFace() throws {
        let ray = MetalRay(origin: [0, 0, 5], direction: [0, 0, -1])
        #expect(try #require(MetalPicking.entryDistance(of: ray, bounds: unitBox)) == 4)
    }

    @Test
    func distanceScalesWithDirectionLength() throws {
        let ray = MetalRay(origin: [0, 0, 5], direction: [0, 0, -2])
        #expect(try #require(MetalPicking.entryDistance(of: ray, bounds: unitBox)) == 2)
    }

    @Test
    func rayStartingInsideEntersAtZero() {
        let ray = MetalRay(origin: [0.5, 0, 0], direction: [1, 1, 1])
        #expect(MetalPicking.entryDistance(of: ray, bounds: unitBox) == 0)
    }

    @Test
    func boxBehindTheRayIsAMiss() {
        let ray = MetalRay(origin: [0, 0, 5], direction: [0, 0, 1])
        #expect(MetalPicking.entryDistance(of: ray, bounds: unitBox) == nil)
    }

    @Test
    func rayPassingBesideTheBoxMisses() {
        let ray = MetalRay(origin: [2, 0, 5], direction: [0, 0, -1])
        #expect(MetalPicking.entryDistance(of: ray, bounds: unitBox) == nil)
    }

    @Test
    func axisAlignedRayOnAFaceCountsAsAHit() {
        // Direction components of zero must not produce NaN.
        let ray = MetalRay(origin: [1, 0, 5], direction: [0, 0, -1])
        #expect(MetalPicking.entryDistance(of: ray, bounds: unitBox) == 4)
    }

    @Test
    func diagonalRayHitsTheNearerFace() throws {
        let ray = MetalRay(origin: [-3, 0.5, 0], direction: simd_normalize([1, 0, 0]))
        #expect(try #require(MetalPicking.entryDistance(of: ray, bounds: unitBox)) == 2)
    }

    // MARK: Ray and triangle

    private let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(2, 0, 0), c = SIMD3<Float>(0, 2, 0)

    @Test
    func rayHitsTriangleFromEitherSide() throws {
        let front = MetalRay(origin: [0.5, 0.5, 3], direction: [0, 0, -1])
        let back = MetalRay(origin: [0.5, 0.5, -3], direction: [0, 0, 1])
        #expect(try #require(MetalPicking.distance(of: front, toTriangle: a, b, c)) == 3)
        #expect(try #require(MetalPicking.distance(of: back, toTriangle: a, b, c)) == 3)
    }

    @Test
    func rayOutsideTheTriangleMisses() {
        // Inside the bounding square but past the hypotenuse.
        let ray = MetalRay(origin: [1.5, 1.5, 3], direction: [0, 0, -1])
        #expect(MetalPicking.distance(of: ray, toTriangle: a, b, c) == nil)
    }

    @Test
    func triangleBehindTheOriginMisses() {
        let ray = MetalRay(origin: [0.5, 0.5, 3], direction: [0, 0, 1])
        #expect(MetalPicking.distance(of: ray, toTriangle: a, b, c) == nil)
    }

    @Test
    func rayParallelToTheTriangleMisses() {
        let ray = MetalRay(origin: [0.5, 0.5, 1], direction: [1, 0, 0])
        #expect(MetalPicking.distance(of: ray, toTriangle: a, b, c) == nil)
    }

    @Test
    func degenerateTriangleMisses() {
        let ray = MetalRay(origin: [0.5, 0, 3], direction: [0, 0, -1])
        #expect(MetalPicking.distance(of: ray, toTriangle: a, b, b) == nil)
        #expect(MetalPicking.distance(of: ray, toTriangle: a, a, a) == nil)
    }

    @Test
    func edgeAndCornerCountAsHits() {
        let edge = MetalRay(origin: [1, 0, 3], direction: [0, 0, -1])
        let corner = MetalRay(origin: [0, 0, 3], direction: [0, 0, -1])
        #expect(MetalPicking.distance(of: edge, toTriangle: a, b, c) == 3)
        #expect(MetalPicking.distance(of: corner, toTriangle: a, b, c) == 3)
    }

    // MARK: Meshes

    private func data<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }

    @Test
    func nearestHitPicksTheClosestOfStackedTriangles() throws {
        // Two copies of the triangle, at z = 0 and z = 1, plus a bad index.
        let positions: [SIMD4<Float>] = [[0, 0, 0, 1], [2, 0, 0, 1], [0, 2, 0, 1],
                                         [0, 0, 1, 1], [2, 0, 1, 1], [0, 2, 1, 1]]
        let indices: [UInt32] = [0, 1, 2, 3, 4, 5, 0, 1, 99]
        let ray = MetalRay(origin: [0.5, 0.5, 5], direction: [0, 0, -1])
        let hit = try data(positions).withUnsafeBytes { p in
            try data(indices).withUnsafeBytes { i in
                try #require(MetalPicking.nearestHit(of: ray, positions: p, indices: i))
            }
        }
        #expect(hit.triangle == 1)
        #expect(hit.distance == 4)
    }

    @Test
    func nearestHitHonoursMaxDistanceAndMisses() {
        let positions: [SIMD4<Float>] = [[0, 0, 0, 1], [2, 0, 0, 1], [0, 2, 0, 1]]
        let indices: [UInt32] = [0, 1, 2]
        let ray = MetalRay(origin: [0.5, 0.5, 5], direction: [0, 0, -1])
        data(positions).withUnsafeBytes { p in
            data(indices).withUnsafeBytes { i in
                #expect(MetalPicking.nearestHit(of: ray, positions: p, indices: i, maxDistance: 4) == nil)
                #expect(MetalPicking.nearestHit(of: ray, positions: p, indices: i, maxDistance: 5)?.triangle == 0)
            }
        }
    }

    // MARK: Screen rays

    @Test
    func centreOfTheViewLooksStraightDownTheCameraAxis() throws {
        let ray = try #require(MetalPicking.ray(throughPoint: [200, 100], viewSize: [400, 200],
                                                halfHeightTangent: 1, sceneFromCamera: matrix_identity_float4x4))
        #expect(ray.origin == .zero)
        #expect(simd_distance(simd_normalize(ray.direction), [0, 0, -1]) < 1e-6)
    }

    @Test
    func cornersFollowTheFieldOfViewAndAspect() throws {
        // Top right of a 2:1 view with tan(half fov) = 1: x = 2, y = 1.
        let ray = try #require(MetalPicking.ray(throughPoint: [400, 0], viewSize: [400, 200],
                                                halfHeightTangent: 1, sceneFromCamera: matrix_identity_float4x4))
        #expect(simd_distance(ray.direction, [2, 1, -1]) < 1e-6)
    }

    @Test
    func screenRayFollowsTheCameraPose() throws {
        // Camera at (0, 10, 0) turned to look down −y: its −z maps to −y.
        let pose = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])) +
            simd_float4x4(columns: (.zero, .zero, .zero, [0, 10, 0, 0]))
        let ray = try #require(MetalPicking.ray(throughPoint: [50, 50], viewSize: [100, 100],
                                                halfHeightTangent: 1, sceneFromCamera: pose))
        #expect(simd_distance(ray.origin, [0, 10, 0]) < 1e-5)
        #expect(simd_distance(simd_normalize(ray.direction), [0, -1, 0]) < 1e-5)
    }

    @Test
    func emptyViewHasNoRay() {
        #expect(MetalPicking.ray(throughPoint: .zero, viewSize: .zero, halfHeightTangent: 1,
                                 sceneFromCamera: matrix_identity_float4x4) == nil)
    }

    @Test
    func rayTransformKeepsDistancesComparable() {
        // Scale-by-2 matrix: a local-space distance equals the scene one.
        let scale = simd_float4x4(diagonal: [2, 2, 2, 1])
        let ray = MetalRay(origin: [0, 0, 4], direction: [0, 0, -1])
        let local = ray.transformed(by: scale.inverse)
        #expect(local.origin == [0, 0, 2])
        #expect(local.direction == [0, 0, -0.5])
        #expect(local.point(at: 4) == [0, 0, 0])
    }
}
