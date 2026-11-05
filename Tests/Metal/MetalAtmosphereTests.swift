import Foundation
import simd
import Testing

struct MetalAtmosphereTests {
    @Test
    func sunDirectionIsAUnitVectorInTheLevelFrame() {
        // North is -z, east +x, up +y.
        let north = MetalAtmosphere.sunDirection(azimuth: 0, elevation: 0)
        #expect(simd_length(north - SIMD3(0, 0, -1)) < 1e-6)
        let east = MetalAtmosphere.sunDirection(azimuth: .pi / 2, elevation: 0)
        #expect(simd_length(east - SIMD3(1, 0, 0)) < 1e-6)
        let high = MetalAtmosphere.sunDirection(azimuth: 1, elevation: .pi / 2)
        #expect(simd_length(high - SIMD3(0, 1, 0)) < 1e-6)
        #expect(abs(simd_length(MetalAtmosphere().sunDirection) - 1) < 1e-6)
    }

    @Test
    func uniformsMatchTheShadersLayout() {
        // A 4x4 matrix and four float4s: 64 + 4 x 16.
        #expect(MemoryLayout<MetalAtmosphere.Uniforms>.stride == 128)
    }

    @Test
    func uniformsPutTheEyeInTheAnchorFrame() {
        // The scene is the anchor frame scaled by 2 and moved 10 m along x.
        var root = matrix_identity_float4x4 * 2
        root.columns.3 = SIMD4(10, 0, 0, 1)
        let uniforms = MetalAtmosphere().uniforms(root: root, eye: [14, 6, 0])
        #expect(simd_length(SIMD3(uniforms.eye.x, uniforms.eye.y, uniforms.eye.z) - SIMD3(2, 3, 0)) < 1e-5)
    }

    @Test
    func clipPointsAtTheFarPlaneComeBackAsRaysFromTheEye() {
        // A level camera at 5 m up looking down -z, and an identity root.
        let projection = MetalProjection.perspective(tangents: [1, 1, 1, 1], near: 1, far: 1000)
        var cameraMatrix = matrix_identity_float4x4
        cameraMatrix.columns.3 = SIMD4(0, 5, 0, 1)
        let anchorFromClip = MetalAtmosphere.anchorFromClip(viewProjection: projection * cameraMatrix.inverse,
                                                             root: matrix_identity_float4x4)
        let far = anchorFromClip * SIMD4<Float>(0, 0, 0, 1)
        let ray = SIMD3(far.x, far.y, far.z) - far.w * SIMD3<Float>(0, 5, 0)
        let direction = simd_normalize(ray)
        #expect(simd_length(direction - SIMD3(0, 0, -1)) < 1e-4)
    }

    @Test
    func passthroughLeavesEverythingEmpty() {
        let passthrough = MetalAtmosphere.passthrough
        #expect(!passthrough.paintsSky)
        #expect(passthrough.hazeStrength == 0)
        #expect(!passthrough.writesSkyDepthWhenUnpainted)
        #expect(MetalAtmosphere.flat.writesSkyDepthWhenUnpainted)
    }

    @Test
    func environmentOverrides() {
        #expect(MetalAtmosphere.fromEnvironment([:]) == MetalAtmosphere())
        #expect(MetalAtmosphere.fromEnvironment(["ALSOMAPS_METAL_ATMOSPHERE": "0"]) == .flat)
        #expect(MetalAtmosphere.fromEnvironment(["ALSOMAPS_METAL_HAZE": "1.5"]).hazeStrength == 1.5)
        let sun = MetalAtmosphere.fromEnvironment(["ALSOMAPS_METAL_SUN": "90, 0"]).sunDirection
        #expect(simd_length(sun - SIMD3(1, 0, 0)) < 1e-6)
    }
}
