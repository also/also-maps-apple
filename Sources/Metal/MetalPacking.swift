import Foundation
import simd

/// Pure conversions from the bridge's vertex streams to the compact formats
/// the Metal renderer uploads. Foundation and simd only, so they're unit
/// tested on macOS (Tests/Metal/MetalPackingTests.swift). RealityKit's
/// TileUploader reads the bridge's streams directly and is unaffected.
///
/// | stream    | bridge            | Metal               |
/// |-----------|-------------------|---------------------|
/// | positions | float4 (16 B)     | snorm16 x3 (6 B)    |
/// | texcoords | float2 (8 B), v flipped for RealityKit | half2 (4 B), v flipped back |
/// | normals   | float4 (16 B)     | octahedral snorm16 x2 (4 B) |
enum MetalPacking {
    static let packedPositionStride = 3 * MemoryLayout<Int16>.size
    static let packedTexcoordStride = 2 * MemoryLayout<UInt16>.size
    static let packedNormalStride = 2 * MemoryLayout<Int16>.size

    // MARK: Positions

    /// The centre and half-extent of a part's box: the decode is
    /// `centre + halfExtent * (snorm16 value)`.
    struct PositionFrame: Equatable {
        let centre: SIMD3<Float>
        let halfExtent: SIMD3<Float>

        init(bounds: MetalBounds) {
            centre = (bounds.minimum + bounds.maximum) / 2
            halfExtent = (bounds.maximum - bounds.minimum) / 2
        }
    }

    /// Nearest snorm16 for `value` in `-1...1` (clamped), as stored.
    static func snorm16(_ value: Float) -> Int16 {
        Int16((max(-1, min(1, value)) * 32767).rounded())
    }

    static func unsnorm16(_ value: Int16) -> Float {
        max(-1, Float(value) / 32767)
    }

    static func quantise(_ position: SIMD3<Float>, in frame: PositionFrame) -> SIMD3<Int16> {
        // A flat axis (zero extent) always decodes to the centre.
        func axis(_ i: Int) -> Int16 {
            let half = frame.halfExtent[i]
            return half > 0 ? snorm16((position[i] - frame.centre[i]) / half) : 0
        }
        return SIMD3(axis(0), axis(1), axis(2))
    }

    static func dequantise(_ packed: SIMD3<Int16>, in frame: PositionFrame) -> SIMD3<Float> {
        frame.centre + frame.halfExtent * SIMD3(unsnorm16(packed.x), unsnorm16(packed.y), unsnorm16(packed.z))
    }

    /// The worst-case error of one axis: half a quantisation step.
    static func maximumPositionError(in frame: PositionFrame) -> SIMD3<Float> {
        frame.halfExtent / 32767 / 2
    }

    /// float4 positions to tightly packed snorm16 x3. nil if the length isn't
    /// a whole number of float4s.
    static func packPositions(_ data: Data, frame: PositionFrame) -> Data? {
        let stride = MemoryLayout<SIMD4<Float>>.stride
        guard !data.isEmpty, data.count.isMultiple(of: stride) else { return nil }
        let count = data.count / stride
        var out = Data(count: count * packedPositionStride)
        data.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { target in
                for i in 0..<count {
                    let v = source.loadUnaligned(fromByteOffset: i * stride, as: SIMD4<Float>.self)
                    let q = quantise(SIMD3(v.x, v.y, v.z), in: frame)
                    let base = i * packedPositionStride
                    target.storeBytes(of: q.x, toByteOffset: base, as: Int16.self)
                    target.storeBytes(of: q.y, toByteOffset: base + 2, as: Int16.self)
                    target.storeBytes(of: q.z, toByteOffset: base + 4, as: Int16.self)
                }
            }
        }
        return out
    }

    // MARK: Texture coordinates

    /// IEEE binary16 bits for `value`, rounded to nearest even. A pure
    /// bit-level version of Float16(value), which Intel Macs don't have.
    static func halfBits(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF)
        let mantissa = bits & 0x7F_FFFF
        if exponent == 0xFF { return sign | 0x7C00 | (mantissa != 0 ? 0x200 : 0) }
        let e = exponent - 127 + 15
        if e >= 0x1F { return sign | 0x7C00 }
        if e <= 0 {
            // Subnormal half, or zero.
            if e < -10 { return sign }
            let full = mantissa | 0x80_0000
            let shift = UInt32(14 - e)
            var half = full >> shift
            let remainder = full & ((1 << shift) - 1)
            let halfway: UInt32 = 1 << (shift - 1)
            if remainder > halfway || (remainder == halfway && half & 1 == 1) { half += 1 }
            return sign | UInt16(half)
        }
        var half = UInt32(e) << 10 | mantissa >> 13
        let remainder = mantissa & 0x1FFF
        // A carry out of the mantissa correctly bumps the exponent (or reaches infinity).
        if remainder > 0x1000 || (remainder == 0x1000 && half & 1 == 1) { half += 1 }
        return sign | UInt16(half)
    }

    static func floatValue(halfBits bits: UInt16) -> Float {
        let sign: Float = bits & 0x8000 != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = Float(bits & 0x3FF)
        switch exponent {
        case 0: return sign * mantissa * 0x1p-24
        case 0x1F: return mantissa == 0 ? sign * .infinity : .nan
        default: return sign * (1 + mantissa / 1024) * Float(sign: .plus, exponent: exponent - 15, significand: 1)
        }
    }

    /// float2 texcoords to half2, with v flipped back (the bridge flips it
    /// for RealityKit; Metal's origin is top-left), so the shader doesn't.
    /// Half has 11 significant bits: about half a texel at 2048 wide near
    /// u = 1, so large textures may want a different format (see the notes).
    static func packTexcoords(_ data: Data) -> Data? {
        let stride = MemoryLayout<SIMD2<Float>>.stride
        guard !data.isEmpty, data.count.isMultiple(of: stride) else { return nil }
        let count = data.count / stride
        var out = Data(count: count * packedTexcoordStride)
        data.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { target in
                for i in 0..<count {
                    let uv = source.loadUnaligned(fromByteOffset: i * stride, as: SIMD2<Float>.self)
                    target.storeBytes(of: halfBits(uv.x), toByteOffset: i * packedTexcoordStride, as: UInt16.self)
                    target.storeBytes(of: halfBits(1 - uv.y), toByteOffset: i * packedTexcoordStride + 2,
                                      as: UInt16.self)
                }
            }
        }
        return out
    }

    // MARK: Normals

    private static func signNotZero(_ v: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(v.x >= 0 ? 1 : -1, v.y >= 0 ? 1 : -1)
    }

    /// Octahedral encoding of a unit vector into two snorm16s. A zero or
    /// non-finite vector encodes as +z.
    static func octEncode(_ normal: SIMD3<Float>) -> SIMD2<Int16> {
        let l1 = abs(normal.x) + abs(normal.y) + abs(normal.z)
        guard l1.isFinite, l1 > 0 else { return SIMD2(0, 0) }
        let p = SIMD2(normal.x, normal.y) / l1
        let e = normal.z >= 0 ? p : (SIMD2<Float>(1, 1) - SIMD2(abs(p.y), abs(p.x))) * signNotZero(p)
        return SIMD2(snorm16(e.x), snorm16(e.y))
    }

    /// The inverse; the MSL `octDecode` in MetalTileRenderer.shaderSource
    /// must do the same.
    static func octDecode(_ packed: SIMD2<Int16>) -> SIMD3<Float> {
        var e = SIMD2(unsnorm16(packed.x), unsnorm16(packed.y))
        let z = 1 - abs(e.x) - abs(e.y)
        if z < 0 { e = (SIMD2<Float>(1, 1) - SIMD2(abs(e.y), abs(e.x))) * signNotZero(e) }
        let n = SIMD3(e.x, e.y, z)
        return n / max(simd_length(n), .leastNormalMagnitude)
    }

    /// float4 normals (xyz + padding) to octahedral snorm16 x2.
    static func packNormals(_ data: Data) -> Data? {
        let stride = MemoryLayout<SIMD4<Float>>.stride
        guard !data.isEmpty, data.count.isMultiple(of: stride) else { return nil }
        let count = data.count / stride
        var out = Data(count: count * packedNormalStride)
        data.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { target in
                for i in 0..<count {
                    let n = source.loadUnaligned(fromByteOffset: i * stride, as: SIMD4<Float>.self)
                    let q = octEncode(SIMD3(n.x, n.y, n.z))
                    target.storeBytes(of: q.x, toByteOffset: i * packedNormalStride, as: Int16.self)
                    target.storeBytes(of: q.y, toByteOffset: i * packedNormalStride + 2, as: Int16.self)
                }
            }
        }
        return out
    }
}

/// Texture compression for the Metal renderer, chosen by the environment.
/// Off unless ALSOMAPS_METAL_ASTC=1.
enum MetalTextureCompression {
    case none, astc6x6

    static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        environment["ALSOMAPS_METAL_ASTC"] == "1" ? .astc6x6 : .none
    }

    /// Bytes for a mipmapped texture, to compare sizes (and in tests).
    static func byteCount(width: Int, height: Int, mipmapped: Bool, compression: Self) -> Int {
        var total = 0, w = max(width, 1), h = max(height, 1)
        while true {
            switch compression {
            case .none: total += w * h * 4
            case .astc6x6: total += ((w + 5) / 6) * ((h + 5) / 6) * 16
            }
            if !mipmapped || (w == 1 && h == 1) { break }
            w = max(w / 2, 1)
            h = max(h / 2, 1)
        }
        return total
    }
}
