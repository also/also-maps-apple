import Foundation
import simd
import Testing

struct MetalPackingTests {
    private let frame = MetalPacking.PositionFrame(
        bounds: MetalBounds(minimum: [-120, -80, -10], maximum: [380, 220, 40]))

    @Test
    func positionsRoundTripWithinHalfAStep() {
        let points: [SIMD3<Float>] = [[-120, -80, -10], [380, 220, 40], [130, 70, 15], [0, 0, 0], [211.3, -5.7, 33.3]]
        let tolerance = MetalPacking.maximumPositionError(in: frame) * 1.01
        for point in points {
            let back = MetalPacking.dequantise(MetalPacking.quantise(point, in: frame), in: frame)
            #expect(abs(back.x - point.x) <= tolerance.x)
            #expect(abs(back.y - point.y) <= tolerance.y)
            #expect(abs(back.z - point.z) <= tolerance.z)
        }
    }

    @Test
    func extremesMapToTheEndsOfTheRange() {
        #expect(MetalPacking.quantise([-120, -80, -10], in: frame) == SIMD3<Int16>(-32767, -32767, -32767))
        #expect(MetalPacking.quantise([380, 220, 40], in: frame) == SIMD3<Int16>(32767, 32767, 32767))
    }

    @Test
    func flatAxisDecodesToItsValue() {
        let flat = MetalPacking.PositionFrame(bounds: MetalBounds(minimum: [0, 5, 0], maximum: [10, 5, 10]))
        let back = MetalPacking.dequantise(MetalPacking.quantise([3, 5, 7], in: flat), in: flat)
        #expect(back.y == 5)
    }

    @Test
    func packedPositionsAreSixBytesAScalarOrdered() throws {
        let vertices: [SIMD4<Float>] = [[-120, -80, -10, 0], [380, 220, 40, 0]]
        let data = vertices.withUnsafeBytes { Data($0) }
        let packed = try #require(MetalPacking.packPositions(data, frame: frame))
        #expect(packed.count == 12)
        let values = packed.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(values == [-32767, -32767, -32767, 32767, 32767, 32767])
        #expect(MetalPacking.packPositions(Data(count: 10), frame: frame) == nil)
        #expect(MetalPacking.packPositions(Data(), frame: frame) == nil)
    }

    @Test(arguments: [(Float(0), UInt16(0)), (1, 0x3C00), (-2, 0xC000), (0.5, 0x3800), (65504, 0x7BFF),
                      (70000, 0x7C00), (0x1p-24, 0x0001), (0x1p-26, 0), (.infinity, 0x7C00)])
    func halfBitsMatchKnownValues(value: Float, bits: UInt16) {
        #expect(MetalPacking.halfBits(value) == bits)
    }

    @Test
    func halfRoundTripsEveryFiniteHalf() {
        for bits in UInt16(0)...UInt16(0x7BFF) {
            #expect(MetalPacking.halfBits(MetalPacking.floatValue(halfBits: bits)) == bits)
        }
    }

    @Test
    func halfRoundsToNearestEven() {
        // Between 1.0 (0x3C00) and the next half, 1 + 2^-10: a tie goes to even.
        #expect(MetalPacking.halfBits(1 + 0x1p-11) == 0x3C00)
        #expect(MetalPacking.halfBits(1 + 3 * 0x1p-11) == 0x3C02)
        #expect(MetalPacking.halfBits(1 + 0x1p-11 + 0x1p-20) == 0x3C01)
    }

    @Test
    func texcoordsFlipVAndKeepU() throws {
        let uvs: [SIMD2<Float>] = [[0.25, 0.25], [1, 0]]
        let packed = try #require(MetalPacking.packTexcoords(uvs.withUnsafeBytes { Data($0) }))
        let bits = packed.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        #expect(bits.count == 4)
        #expect(MetalPacking.floatValue(halfBits: bits[0]) == 0.25)
        #expect(MetalPacking.floatValue(halfBits: bits[1]) == 0.75)
        #expect(MetalPacking.floatValue(halfBits: bits[2]) == 1)
        #expect(MetalPacking.floatValue(halfBits: bits[3]) == 1)
    }

    @Test(arguments: [SIMD3<Float>(0, 0, 1), [0, 0, -1], [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0],
                      [0.6, -0.48, 0.64], [-0.3, 0.2, -0.93], [0.577, 0.577, -0.577]])
    func normalsRoundTripToWithinAFewThousandths(normal: SIMD3<Float>) {
        let unit = simd_normalize(normal)
        let back = MetalPacking.octDecode(MetalPacking.octEncode(unit))
        #expect(simd_length(back - unit) < 0.002)
        #expect(abs(simd_length(back) - 1) < 1e-5)
    }

    @Test
    func degenerateNormalsDecodeToUnitLength() {
        #expect(simd_length(MetalPacking.octDecode(MetalPacking.octEncode([0, 0, 0]))) > 0.99)
        #expect(simd_length(MetalPacking.octDecode(MetalPacking.octEncode([.nan, 0, 1]))) > 0.99)
    }

    @Test
    func packedNormalsAreFourBytes() throws {
        let normals: [SIMD4<Float>] = [[0, 0, 1, 0], [0, 1, 0, 0]]
        let packed = try #require(MetalPacking.packNormals(normals.withUnsafeBytes { Data($0) }))
        #expect(packed.count == 8)
    }

    @Test
    func compressionIsOffUnlessAskedFor() {
        #expect(MetalTextureCompression.current([:]) == .none)
        #expect(MetalTextureCompression.current(["ALSOMAPS_METAL_ASTC": "0"]) == .none)
        #expect(MetalTextureCompression.current(["ALSOMAPS_METAL_ASTC": "1"]) == .astc6x6)
    }

    @Test
    func astcIsAboutAnEighthOfRGBA8() {
        let raw = MetalTextureCompression.byteCount(width: 512, height: 512, mipmapped: true, compression: .none)
        let astc = MetalTextureCompression.byteCount(width: 512, height: 512, mipmapped: true, compression: .astc6x6)
        #expect(raw == 1_398_100)
        #expect(Double(astc) / Double(raw) < 0.13)
        #expect(MetalTextureCompression.byteCount(width: 512, height: 512, mipmapped: false, compression: .astc6x6)
                == 86 * 86 * 16)
    }
}
