import Foundation
import simd
import Testing

struct MetalSunTests {
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test
    func equinoxNoonAtTheEquatorIsNearlyOverhead() {
        let sun = MetalSun.position(latitude: 0, longitude: 0, date: date("2024-03-20T12:00:00Z"))
        #expect(sun.elevation > 85)
    }

    @Test
    func midwinterNoonInLondonIsLowAndSouth() {
        let sun = MetalSun.position(latitude: 51.5, longitude: 0, date: date("2024-12-21T12:00:00Z"))
        #expect(abs(sun.elevation - 15) < 1)
        #expect(abs(sun.azimuth - 180) < 3)
    }

    @Test
    func midnightIsBelowTheHorizon() {
        let sun = MetalSun.position(latitude: 0, longitude: 0, date: date("2024-03-20T00:00:00Z"))
        #expect(sun.elevation < 0)
    }

    @Test
    func directionIsAUnitVectorWithUpFromElevation() {
        let sun = MetalSun.position(latitude: 40, longitude: -74, date: date("2024-06-21T16:00:00Z"))
        let direction = sun.eastNorthUp
        #expect(abs(simd_length(direction) - 1) < 1e-9)
        #expect(abs(direction.z - sin(sun.elevation * .pi / 180)) < 1e-9)
    }
}

struct MetalUniformsLayoutTests {
    // These sizes are asserted again in the shader source (static_assert),
    // so a mismatch fails loudly at launch as well.
    @Test
    func frameUniformsMatchTheShaderLayout() {
        #expect(MemoryLayout<MetalFrameUniforms>.size == 128)
        #expect(MemoryLayout<MetalFrameUniforms>.stride == 128)
        #expect(MemoryLayout<MetalFrameUniforms>.offset(of: \.cameraPositionAndTime) == 64)
        #expect(MemoryLayout<MetalFrameUniforms>.offset(of: \.exposure) == 112)
    }

    @Test
    func tileUniformsMatchTheShaderLayout() {
        #expect(MemoryLayout<MetalTileUniforms>.size == 160)
        #expect(MemoryLayout<MetalTileUniforms>.stride == 160)
        #expect(MemoryLayout<MetalTileUniforms>.offset(of: \.baseColor) == 128)
        #expect(MemoryLayout<MetalTileUniforms>.offset(of: \.flags) == 144)
    }
}
