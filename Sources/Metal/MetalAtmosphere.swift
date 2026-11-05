import Foundation
import simd

/// The sky, sun and haze the Metal renderer draws (experimental). A local
/// struct on purpose: when a shared frame-uniform block with a sun exists
/// (notes/metal-feature-ideas.md, idea 3), fill `sunDirection` from that and
/// delete the rest of the sun handling here.
///
/// Everything is in the streaming anchor's level frame: x east, y up, z
/// south, metres, the anchor (the focus) at the origin. That is the frame a
/// real sun position would come in, and it stays in metres whatever scale the
/// scene is drawn at. The renderer converts the camera into it each frame.
///
/// Colour is computed in linear light; the targets are sRGB and encode it.
struct MetalAtmosphere: Equatable {
    /// Unit vector from the scene towards the sun. The default is a morning
    /// sun in the south-east, 45° up, roughly what the photogrammetry's baked
    /// light looks like. Not a real position for any place or time.
    var sunDirection = MetalAtmosphere.sunDirection(azimuth: 160 * .pi / 180, elevation: 45 * .pi / 180)
    /// Radians. The real sun is 0.0047; this is doubled so the disc is a few
    /// pixels across in a headset.
    var sunAngularRadius: Float = 0.0094

    /// Paints the sky (gradient, scattering and the sun) where nothing is
    /// drawn. Off, the flat clear colour shows, or passthrough where the
    /// target is transparent.
    var paintsSky = true
    /// When the sky isn't painted, still moves the empty pixels to
    /// `MetalTileRenderer.skyDepth` in a compositor, so the clear colour isn't
    /// dropped as clipped (notes/metal-renderer.md, 2026-11-04). Turn off for
    /// passthrough, where those pixels should stay empty.
    var writesSkyDepthWhenUnpainted = true

    /// Aerial perspective: tile colour fades toward the sky's colour with
    /// distance and height. 1 is a clear day by the physical coefficients, 0
    /// is none. The default is deliberately subtle.
    var hazeStrength: Float = 0.5
    /// The haze thins out exponentially with height, with this scale height
    /// (metres) above `groundHeight`.
    var hazeScaleHeight: Float = 1500
    /// Anchor-frame height (metres) where the haze is densest. The anchor
    /// sits on the ground at the focus, so 0 is right until it isn't.
    var groundHeight: Float = 0

    /// How hazy the air is: the vertical optical depth of the grey
    /// (Mie) part. About 0.02 is clear, 0.1 is milky.
    var turbidity: Float = 0.02
    /// Scales the sky's brightness before tone mapping, 1 - exp(-x).
    var skyIntensity: Float = 4
    /// Scales the sun disc's colour, which saturates to white.
    var sunBrightness: Float = 3

    /// The old look: a flat clear colour and the depth-only sky pass.
    static var flat: MetalAtmosphere {
        var atmosphere = MetalAtmosphere()
        atmosphere.paintsSky = false
        atmosphere.hazeStrength = 0
        return atmosphere
    }

    /// For a mixed-immersion presentation: nothing painted, nothing hazed,
    /// and the empty pixels left empty so passthrough shows.
    static var passthrough: MetalAtmosphere {
        var atmosphere = flat
        atmosphere.writesSkyDepthWhenUnpainted = false
        return atmosphere
    }

    /// Environment overrides, for comparing on a device without a rebuild:
    /// - `ALSOMAPS_METAL_ATMOSPHERE=0`: the old flat sky, no haze.
    /// - `ALSOMAPS_METAL_HAZE=<number>`: haze strength (0 none, 1 physical).
    /// - `ALSOMAPS_METAL_SUN=<azimuth>,<elevation>`: degrees, azimuth from
    ///   north through east.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> MetalAtmosphere {
        var atmosphere = environment["ALSOMAPS_METAL_ATMOSPHERE"] == "0" ? flat : MetalAtmosphere()
        if let haze = environment["ALSOMAPS_METAL_HAZE"].flatMap(Float.init), haze >= 0 {
            atmosphere.hazeStrength = haze
        }
        if let sun = environment["ALSOMAPS_METAL_SUN"] {
            let degrees = sun.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            if degrees.count == 2 {
                atmosphere.sunDirection = sunDirection(azimuth: degrees[0] * .pi / 180,
                                                       elevation: degrees[1] * .pi / 180)
            }
        }
        return atmosphere
    }

    /// Azimuth from north through east, elevation above the horizon, both
    /// radians, as a unit vector in the anchor's level frame (x east, y up,
    /// z south).
    static func sunDirection(azimuth: Float, elevation: Float) -> SIMD3<Float> {
        SIMD3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation))
    }

    /// Must match AtmosphereUniforms in the shader source.
    struct Uniforms {
        var anchorFromScene: simd_float4x4
        /// xyz: unit vector to the sun. w: its angular radius.
        var sun: SIMD4<Float>
        /// xyz: the eye, in the anchor frame.
        var eye: SIMD4<Float>
        /// x: strength (0 is no haze). y: scale height. z: ground height. w: turbidity.
        var haze: SIMD4<Float>
        /// x: sky intensity. y: sun brightness.
        var sky: SIMD4<Float>
    }

    /// The shader's inputs for a view whose eye is `eye` in the scene, where
    /// `root` takes the anchor's frame to the scene.
    func uniforms(root: simd_float4x4, eye: SIMD3<Float>) -> Uniforms {
        let anchorFromScene = root.inverse
        let eyeInAnchor = anchorFromScene * SIMD4(eye, 1)
        let sun = simd_normalize(sunDirection)
        return Uniforms(anchorFromScene: anchorFromScene,
                        sun: SIMD4(sun, sunAngularRadius),
                        eye: SIMD4(eyeInAnchor.x, eyeInAnchor.y, eyeInAnchor.z, 0),
                        haze: SIMD4(max(hazeStrength, 0), max(hazeScaleHeight, 1), groundHeight, max(turbidity, 0)),
                        sky: SIMD4(skyIntensity, sunBrightness, 0, 0))
    }

    /// Takes a clip-space point to the anchor frame, for the sky's rays.
    static func anchorFromClip(viewProjection: simd_float4x4, root: simd_float4x4) -> simd_float4x4 {
        root.inverse * viewProjection.inverse
    }

    /// Metal Shading Language for the sky and the aerial perspective. Spliced
    /// into the renderer's shader source after the tile uniforms. No
    /// backslashes: it sits in a Swift string.
    static let shaderSource = """
// Must match MetalAtmosphere.Uniforms.
struct AtmosphereUniforms {
    float4x4 anchorFromScene;
    float4 sun;    // xyz unit vector to the sun, w angular radius
    float4 eye;    // xyz eye in the anchor frame, metres
    float4 haze;   // strength, scale height, ground height, turbidity
    float4 sky;    // intensity, sun brightness
};

// Sea-level Rayleigh scattering per metre (red, green, blue) and the heights
// the two parts of the air thin out with.
constant float3 kRayleigh = float3(5.8e-6, 13.5e-6, 33.1e-6);
constant float kRayleighHeight = 8000.0;
constant float kMieHeight = 1200.0;
constant float kMieAnisotropy = 0.76;

/// Single-scattered light from a plane-parallel atmosphere, in closed form:
/// the sky seen along `dir` (unit, y up), already tone mapped to the display's
/// linear range. Looking below the horizon gives the horizon's colour, so a
/// gap in the ground reads as haze.
float3 skyRadiance(float3 dir, constant AtmosphereUniforms &atmosphere) {
    float3 sunDirection = atmosphere.sun.xyz;
    float3 rayleighDepth = kRayleigh * kRayleighHeight;
    float3 depth = rayleighDepth + atmosphere.haze.w;
    float viewUp = max(dir.y, 0.02);
    float sunUp = max(sunDirection.y, 0.0) + 0.02;

    float cosine = dot(dir, sunDirection);
    float rayleighPhase = 0.75 * (1.0 + cosine * cosine);
    float g = kMieAnisotropy;
    float miePole = 1.0 + g * g - 2.0 * g * cosine;
    float miePhase = (1.0 - g * g) / (miePole * sqrt(miePole));
    float3 rayleighShare = rayleighDepth / depth;
    float3 phase = rayleighShare * rayleighPhase + (1.0 - rayleighShare) * miePhase;

    float3 scattered = (sunUp / (sunUp + viewUp))
        * (1.0 - exp(-depth * (1.0 / viewUp + 1.0 / sunUp))) * phase;
    float daylight = smoothstep(-0.1, 0.05, sunDirection.y);
    float3 night = float3(0.004, 0.007, 0.016);
    return 1.0 - exp(-atmosphere.sky.x * (scattered * daylight + night));
}

/// Fades `colour`, a tile's colour at `anchorPosition` (anchor frame), toward
/// the sky's colour along the same view ray. The air thins out exponentially
/// with height, so the amount of it between the eye and the point is the
/// integral of that density along the segment, in closed form.
float3 applyHaze(float3 colour, float3 anchorPosition, constant AtmosphereUniforms &atmosphere) {
    float3 eye = atmosphere.eye.xyz;
    float3 toPoint = anchorPosition - eye;
    float segment = length(toPoint);
    float3 view = toPoint / max(segment, 0.001);
    float scaleHeight = atmosphere.haze.y;
    float ground = atmosphere.haze.z;
    float densityAtEye = exp(clamp(-(eye.y - ground) / scaleHeight, -60.0, 20.0));
    float densityAtPoint = exp(clamp(-(anchorPosition.y - ground) / scaleHeight, -60.0, 20.0));
    float rise = anchorPosition.y - eye.y;
    // Nearly level segments would divide by almost zero.
    float column = abs(rise) > 1.0
        ? segment * scaleHeight * (densityAtEye - densityAtPoint) / rise
        : segment * 0.5 * (densityAtEye + densityAtPoint);
    float3 extinction = atmosphere.haze.x * (kRayleigh + atmosphere.haze.w / kMieHeight);
    float3 transmittance = exp(-extinction * column);
    return colour * transmittance + skyRadiance(view, atmosphere) * (1.0 - transmittance);
}

struct SkyOut {
    float4 position [[position]];
    float3 ray;
};

/// One triangle covering the view at a fixed depth. The ray is the
/// unprojected far end of each corner's pixel ray in the anchor frame, as a
/// homogeneous point so an infinite far plane works. It is linear across the
/// screen, so the interpolated value is exact. Interpolating a varying
/// rather than reading [[position]] keeps it right under foveation's
/// rasterization rate maps.
vertex SkyOut skyVertex(uint vid [[vertex_id]],
                        constant float &depth [[buffer(0)]],
                        constant AtmosphereUniforms &atmosphere [[buffer(1)]],
                        constant float4x4 &anchorFromClip [[buffer(2)]]) {
    float2 corner = float2((vid << 1) & 2, vid & 2);
    float2 ndc = corner * 2 - 1;
    float4 farPoint = anchorFromClip * float4(ndc, 0, 1);
    SkyOut out;
    out.position = float4(ndc, depth, 1);
    out.ray = farPoint.xyz - farPoint.w * atmosphere.eye.xyz;
    return out;
}

fragment float4 skyFragment(SkyOut in [[stage_in]],
                            constant AtmosphereUniforms &atmosphere [[buffer(0)]]) {
    float3 dir = normalize(in.ray);
    float3 colour = skyRadiance(dir, atmosphere);

    // The sun: a disc, reddened and dimmed by the air it crosses.
    float3 sunDirection = atmosphere.sun.xyz;
    float3 depth = kRayleigh * kRayleighHeight + atmosphere.haze.w;
    float3 sunColour = saturate(exp(-depth / max(sunDirection.y, 0.06)) * atmosphere.sky.y);
    float radius = atmosphere.sun.w;
    float disc = 1.0 - smoothstep(0.9 * radius, 1.1 * radius, length(cross(dir, sunDirection)));
    disc *= step(0.0, dot(dir, sunDirection)) * smoothstep(-0.02, 0.02, dir.y);
    colour = mix(colour, sunColour, disc);

    // Half a step of 8-bit noise, in roughly sRGB terms, against banding in
    // the smooth gradient.
    float noise = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
    float3 encoded = sqrt(max(colour, 0.0)) + (noise - 0.5) / 255.0;
    return float4(max(encoded, 0.0) * max(encoded, 0.0), 1);
}
"""
}
