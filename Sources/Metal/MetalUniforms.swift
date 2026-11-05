import simd

/// Data that is the same for every tile in an encode call, bound once.
/// Must match FrameUniforms in MetalTileRenderer's `shaderSource`.
struct MetalFrameUniforms {
    /// Scene → clip, reverse Z.
    var viewProjection: simd_float4x4
    /// xyz: the camera in scene space. w: time in seconds.
    var cameraPositionAndTime: SIMD4<Float>
    /// xyz: unit vector toward the sun, in scene space. w unused.
    var sunDirection: SIMD4<Float>
    /// rgb: the sun's linear colour and intensity. w unused.
    var sunColour: SIMD4<Float>
    /// Linear multiplier applied before the tone curve.
    var exposure: Float
    /// 0: identity (exposure only). 1: filmic (ACES approximation).
    var toneCurve: UInt32
    var padding: SIMD2<UInt32> = .zero
}

/// Data that differs per tile or part, bound per part.
/// Must match TileUniforms in MetalTileRenderer's `shaderSource`.
struct MetalTileUniforms {
    var modelViewProjection: simd_float4x4
    var model: simd_float4x4
    var baseColor: SIMD4<Float>
    var flags: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
    var padding2: UInt32 = 0
}

/// What a caller supplies about the frame. The defaults reproduce the
/// renderer's original look: exposure 1, no tone curve, and the fixed
/// above-and-slightly-aside light that untextured content was shaded with.
struct MetalFrameState {
    enum ToneCurve: UInt32 { case identity = 0, filmic = 1 }

    /// The camera in scene space.
    var cameraPosition: SIMD3<Float> = .zero
    /// Seconds, for animated shaders.
    var time: Float = 0
    /// Unit vector toward the sun, in scene space (+Y up).
    var sunDirection: SIMD3<Float> = simd_normalize(SIMD3<Float>(0.3, 1, 0.2))
    var sunColour: SIMD3<Float> = SIMD3(repeating: 1)
    var exposure: Float = 1
    var toneCurve: ToneCurve = .identity
}
