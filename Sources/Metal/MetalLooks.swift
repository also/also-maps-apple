import Foundation
import Metal
import simd

/// Alternative looks for the Metal renderer (Settings › General › Look),
/// for fun: each swaps in its own pipelines, so Normal draws exactly as
/// before. Some only change the fragment shader; Tiny planet and Inside
/// out bend the geometry in the vertex shader; Halftone reworks the finished image in a
/// full-screen pass that reads the pixel it's over (framebuffer fetch), so
/// it stays inside the host's render pass and works the same with
/// dedicated eye textures, rasterization-rate maps and reverse Z.
enum MetalLook: String, CaseIterable, Identifiable {
    case normal
    case contours
    case thermal
    case blueprint
    case tinyPlanet
    case insideOut
    case sonar
    case halftone

    var id: Self { self }

    /// UserDefaults key for the setting.
    static let key = "MetalLook"

    /// The setting, or ALSOMAPS_METAL_LOOK=<rawValue> for a run.
    static var current: MetalLook {
        let name = ProcessInfo.processInfo.environment["ALSOMAPS_METAL_LOOK"]
            ?? UserDefaults.standard.string(forKey: key)
        return name.flatMap(MetalLook.init(rawValue:)) ?? .normal
    }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .contours: "Contours"
        case .thermal: "Thermal"
        case .blueprint: "Blueprint"
        case .tinyPlanet: "Tiny planet"
        case .insideOut: "Inside out"
        case .sonar: "Sonar"
        case .halftone: "Halftone"
        }
    }

    /// Names in `MetalLooks.shaderSource`; nil where the look keeps the
    /// cleared sky or needs no full-screen pass.
    fileprivate var functions: (tiles: String, sky: String?, post: String?) {
        switch self {
        case .normal: ("plainFragment", nil, nil)
        case .contours: ("contoursFragment", "contoursSky", nil)
        case .thermal: ("thermalFragment", "thermalSky", nil)
        case .blueprint: ("blueprintFragment", "blueprintSky", nil)
        case .tinyPlanet: ("planetFragment", "planetSky", nil)
        case .insideOut: ("planetFragment", "planetSky", nil)
        case .sonar: ("sonarFragment", "sonarSky", nil)
        case .halftone: ("plainFragment", nil, "halftonePost")
        }
    }

    /// Moves vertices, so culling by the undistorted bounds would be wrong.
    fileprivate var bendsGeometry: Bool { bendRadius(eyeHeight: 1) != 0 }

    /// The sphere the ground is bent onto, scaled to the eye's height above
    /// the anchor so it reads the same from a street or a plane: positive
    /// with its centre below (a planet under you), negative above (the
    /// ground curling up overhead). 0: no bending.
    fileprivate func bendRadius(eyeHeight: Float) -> Float {
        switch self {
        case .tinyPlanet: max(4 * eyeHeight, 300)
        case .insideOut: -max(4 * eyeHeight, 300)
        default: 0
        }
    }
}

/// The looks' pipelines and drawing. A separate library from the main
/// shaders, compiled on first use, so a GPU without a feature a look needs
/// (barycentrics, framebuffer fetch) only loses the looks.
final class MetalLooks: @unchecked Sendable {
    private let device: MTLDevice
    private let library: MTLLibrary
    private let tileDepth: MTLDepthStencilState
    private let skyDepth: MTLDepthStencilState
    private let postDepth: MTLDepthStencilState
    private var pipelines: [Key: MTLRenderPipelineState?] = [:]
    private let pipelinesLock = NSLock()
    private let start = ProcessInfo.processInfo.systemUptime
    private let cullsOffscreen = ProcessInfo.processInfo.environment["ALSOMAPS_METAL_CULLING"] != "0"

    private enum Stage: Int { case tiles, sky, post }
    private struct Key: Hashable {
        let look: MetalLook, colour: MTLPixelFormat, depth: MTLPixelFormat, stage: Stage
    }

    init?(device: MTLDevice) {
        self.device = device
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            print("[AlsoMaps] Metal looks unavailable: \(error)")
            return nil
        }
        func state(_ compare: MTLCompareFunction, writes: Bool) -> MTLDepthStencilState? {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare
            descriptor.isDepthWriteEnabled = writes
            return device.makeDepthStencilState(descriptor: descriptor)
        }
        // Sky: only where nothing was drawn (still at the cleared far
        // plane), without moving depth. Post: everything, depth untouched.
        guard let tileDepth = state(.greater, writes: true), let skyDepth = state(.greater, writes: false),
              let postDepth = state(.always, writes: false)
        else { return nil }
        self.tileDepth = tileDepth
        self.skyDepth = skyDepth
        self.postDepth = postDepth
    }

    /// Must match LookDraw in `shaderSource`.
    private struct Draw {
        var clipFromLocal: simd_float4x4
        var clipFromAnchor: simd_float4x4
        var anchorFromLocal: simd_float4x4
        var baseColor: SIMD4<Float>
        var flags: UInt32
    }

    /// Must match LookFrame in `shaderSource`. Directions and the eye are
    /// in the anchor's level frame (x east, y up, z south, metres).
    private struct Frame {
        var anchorFromClip: simd_float4x4
        /// xyz: the eye; w: seconds, wrapping every 10 minutes.
        var eyeTime: SIMD4<Float>
        /// x: the anchor's height above the ellipsoid; y: the bend radius
        /// (MetalLook.bendRadius).
        var parameters: SIMD4<Float>
    }

    private func pipeline(_ key: Key) -> MTLRenderPipelineState? {
        pipelinesLock.lock()
        defer { pipelinesLock.unlock() }
        if let pipeline = pipelines[key] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        let functions = key.look.functions
        do {
            switch key.stage {
            case .tiles:
                let constants = MTLFunctionConstantValues()
                var bends = key.look.bendsGeometry
                constants.setConstantValue(&bends, type: .bool, index: 0)
                descriptor.vertexFunction = try library.makeFunction(name: "lookVertex", constantValues: constants)
                descriptor.fragmentFunction = library.makeFunction(name: functions.tiles)
            case .sky:
                descriptor.vertexFunction = library.makeFunction(name: "lookScreenVertex")
                descriptor.fragmentFunction = functions.sky.flatMap(library.makeFunction(name:))
            case .post:
                descriptor.vertexFunction = library.makeFunction(name: "lookScreenVertex")
                descriptor.fragmentFunction = functions.post.flatMap(library.makeFunction(name:))
            }
            descriptor.colorAttachments[0].pixelFormat = key.colour
            descriptor.depthAttachmentPixelFormat = key.depth
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = pipeline
            return pipeline
        } catch {
            print("[AlsoMaps] Metal look \(key.look.rawValue) unavailable: \(error)")
            pipelines[key] = .some(nil)
            return nil
        }
    }

    /// As MetalTileRenderer.encode, in `look`; nil if the look can't be
    /// drawn here, for the caller to draw normally instead. Without
    /// `opaqueSky` the look's sky isn't drawn, and the post pass keeps the
    /// finished pixel's alpha, so passthrough shows where there's no map.
    func encode(_ look: MetalLook, _ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat,
                viewProjection: simd_float4x4, root: simd_float4x4, anchorHeight: Double,
                opaqueSky: Bool, tiles: [(tile: CNTileMesh, placement: simd_float4x4)]) -> MetalDrawStatistics? {
        let functions = look.functions
        guard let tilePipeline = pipeline(Key(look: look, colour: colour, depth: depth, stage: .tiles)) else { return nil }
        let skyPipeline = functions.sky == nil || !opaqueSky ? nil : pipeline(Key(look: look, colour: colour, depth: depth, stage: .sky))
        let postPipeline = functions.post == nil ? nil : pipeline(Key(look: look, colour: colour, depth: depth, stage: .post))
        if functions.post != nil, postPipeline == nil { return nil }

        let clipFromAnchor = viewProjection * root
        var frame = Self.frame(look, clipFromAnchor: clipFromAnchor, anchorHeight: Float(anchorHeight),
                               time: Float((ProcessInfo.processInfo.systemUptime - start)
                                   .truncatingRemainder(dividingBy: 600)))

        encoder.setRenderPipelineState(tilePipeline)
        encoder.setDepthStencilState(tileDepth)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 4)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
        let culls = cullsOffscreen && !look.bendsGeometry
        var statistics = MetalDrawStatistics()
        for (tile, placement) in tiles {
            guard let gpu = tile.renderObject as? MetalTileRenderer.Tile else { continue }
            statistics.tiles += 1
            statistics.totalDrawCalls += gpu.parts.count
            statistics.totalTriangles += gpu.triangleCount
            let clipFromLocal = clipFromAnchor * placement
            let frustum = culls ? MetalFrustum(clipFromLocal: clipFromLocal) : nil
            if frustum?.intersects(gpu.bounds) == false { continue }
            var drewTile = false
            for part in gpu.parts {
                if gpu.parts.count > 1, frustum?.intersects(part.bounds) == false { continue }
                if !drewTile {
                    statistics.submittedTiles += 1
                    drewTile = true
                }
                statistics.drawCalls += 1
                statistics.triangles += part.indexCount / 3
                var flags: UInt32 = 0
                if part.texcoords != nil, part.texture != nil { flags |= 1 }
                if part.normals != nil { flags |= 2 }
                var draw = Draw(clipFromLocal: clipFromLocal, clipFromAnchor: clipFromAnchor,
                                anchorFromLocal: placement, baseColor: part.baseColor, flags: flags)
                encoder.setVertexBuffer(part.positions, offset: 0, index: 0)
                encoder.setVertexBuffer(part.texcoords ?? part.positions, offset: 0, index: 1)
                encoder.setVertexBuffer(part.normals ?? part.positions, offset: 0, index: 2)
                encoder.setVertexBytes(&draw, length: MemoryLayout<Draw>.stride, index: 3)
                encoder.setFragmentBytes(&draw, length: MemoryLayout<Draw>.stride, index: 0)
                encoder.setFragmentTexture(part.texture, index: 0)
                encoder.setFragmentSamplerState(part.sampler, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32,
                                              indexBuffer: part.indices, indexBufferOffset: 0)
            }
        }

        // One triangle over the view at the smallest normal depth, so the
        // sky pass passes only where depth is still the cleared 0.
        var screenDepth: Float = 1e-30
        if let skyPipeline {
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setDepthStencilState(skyDepth)
            encoder.setVertexBytes(&screenDepth, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if let postPipeline {
            encoder.setRenderPipelineState(postPipeline)
            encoder.setDepthStencilState(postDepth)
            encoder.setVertexBytes(&screenDepth, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        return statistics
    }

    /// The per-view uniforms. The eye is the point the projection sends to
    /// w = 0 with x = y = 0, which holds for any perspective (off-axis,
    /// reverse or infinite Z), so neither host has to pass it.
    private static func frame(_ look: MetalLook, clipFromAnchor: simd_float4x4, anchorHeight: Float, time: Float) -> Frame {
        let anchorFromClip = clipFromAnchor.inverse
        let eyeH = anchorFromClip * SIMD4<Float>(0, 0, 1, 0)
        let eye = SIMD3(eyeH.x, eyeH.y, eyeH.z) / eyeH.w
        let radius = look.bendRadius(eyeHeight: eye.y)
        return Frame(anchorFromClip: anchorFromClip, eyeTime: SIMD4(eye, time),
                     parameters: SIMD4(anchorHeight, radius, 0, 0))
    }

    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// Must match MetalLooks.Draw.
struct LookDraw {
    float4x4 clipFromLocal;
    float4x4 clipFromAnchor;
    float4x4 anchorFromLocal;
    float4 baseColor;
    uint flags;
};

// Must match MetalLooks.Frame.
struct LookFrame {
    float4x4 anchorFromClip;
    float4 eyeTime;
    float4 parameters;
};

constant uint kTextured = 1;
constant uint kLit = 2;
constant bool kBends [[function_constant(0)]];
constant float kEarthRadius = 6371000.0;

struct LookVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 normal;
    /// Before any bending: what the patterns are drawn on.
    float3 anchorPosition;
};

/// Tiny planet and Inside out: roll the level frame onto a sphere that
/// touches the ground under the eye, from outside (centre below) or inside
/// (centre above), keeping each point's height above the ground. Distance
/// is true near the eye and squeezed farther out, so the whole streamed
/// area ends at the far pole instead of wrapping round the sphere again.
static float3 bend(float3 p, constant LookFrame &frame) {
    float side = sign(frame.parameters.y);
    float radius = abs(frame.parameters.y);
    float2 offset = p.xz - frame.eyeTime.xz;
    float distance = length(offset);
    if (distance < 1e-3) return p;
    float angle = M_PI_F * tanh(distance / (M_PI_F * radius));
    float lifted = radius + side * p.y;
    float2 around = offset / distance * lifted * sin(angle);
    return float3(frame.eyeTime.x + around.x, side * (lifted * cos(angle) - radius), frame.eyeTime.z + around.y);
}

vertex LookVertexOut lookVertex(uint vid [[vertex_id]],
                                const device float4 *positions [[buffer(0)]],
                                const device float2 *texcoords [[buffer(1)]],
                                const device float4 *normals [[buffer(2)]],
                                constant LookDraw &draw [[buffer(3)]],
                                constant LookFrame &frame [[buffer(4)]]) {
    LookVertexOut out;
    float4 local = float4(positions[vid].xyz, 1);
    float3 anchor = (draw.anchorFromLocal * local).xyz;
    out.anchorPosition = anchor;
    if (kBends) {
        out.position = draw.clipFromAnchor * float4(bend(anchor, frame), 1);
    } else {
        // Straight from the tile's frame, as tileVertex does, for precision.
        out.position = draw.clipFromLocal * local;
    }
    out.uv = (draw.flags & kTextured) ? float2(texcoords[vid].x, 1 - texcoords[vid].y) : float2(0);
    out.normal = (draw.flags & kLit) ? (draw.anchorFromLocal * float4(normals[vid].xyz, 0)).xyz : float3(0, 1, 0);
    return out;
}

/// tileFragment's colour: the photogrammetry, or lit untextured content.
static float4 baseColour(LookVertexOut in, texture2d<float> texture, sampler s, constant LookDraw &draw) {
    float4 colour = draw.baseColor;
    if (draw.flags & kTextured) colour *= texture.sample(s, in.uv);
    if (draw.flags & kLit) {
        float light = max(dot(normalize(in.normal), normalize(float3(0.3, 1, 0.2))), 0.0);
        colour.rgb *= 0.55 + 0.45 * light;
    }
    return colour;
}

static float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// The face's normal from screen derivatives, turned towards the eye.
/// Photogrammetry has no normals of its own.
static float3 faceNormal(float3 p, constant LookFrame &frame) {
    float3 n = normalize(cross(dfdx(p), dfdy(p)));
    return dot(n, frame.eyeTime.xyz - p) < 0 ? -n : n;
}

/// 1 on a line every `interval` of `value`, about `width` pixels wide,
/// fading out as lines crowd together.
static float lines(float value, float interval, float width) {
    float w = max(fwidth(value), 1e-5);
    float distance = abs(fract(value / interval + 0.5) - 0.5) * interval;
    float line = 1 - smoothstep(0.5 * width * w, (0.5 * width + 1) * w, distance);
    return line * saturate(1.5 - 6 * w / interval);
}

static float hash(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float noise(float3 p) {
    float3 i = floor(p), f = fract(p);
    f = f * f * (3 - 2 * f);
    return mix(mix(mix(hash(i), hash(i + float3(1, 0, 0)), f.x),
                   mix(hash(i + float3(0, 1, 0)), hash(i + float3(1, 1, 0)), f.x), f.y),
               mix(mix(hash(i + float3(0, 0, 1)), hash(i + float3(1, 0, 1)), f.x),
                   mix(hash(i + float3(0, 1, 1)), hash(i + float3(1, 1, 1)), f.x), f.y), f.z);
}

static float3 srgbToLinear(float3 c) { return pow(c, 2.2); }

fragment float4 plainFragment(LookVertexOut in [[stage_in]],
                              texture2d<float> texture [[texture(0)]], sampler s [[sampler(0)]],
                              constant LookDraw &draw [[buffer(0)]]) {
    return baseColour(in, texture, s, draw);
}

// MARK: Contours

/// Height above the ellipsoid: the anchor's, the level frame's y, and the
/// earth curving away from the anchor.
static float ellipsoidHeight(float3 p, constant LookFrame &frame) {
    return frame.parameters.x + p.y + dot(p.xz, p.xz) / (2 * kEarthRadius);
}

/// A printed map's layer tints, in 10 m steps. Heights are above the
/// ellipsoid, not sea level (the geoid is up to 100 m off), so there's no
/// water tint; the scale starts low enough for most coasts.
static float3 hypsometric(float h) {
    h = floor(h / 10) * 10 + 60;
    const float3 stops[6] = { float3(0.66, 0.80, 0.58), float3(0.80, 0.86, 0.60), float3(0.93, 0.88, 0.64),
                              float3(0.88, 0.74, 0.56), float3(0.78, 0.64, 0.54), float3(0.97, 0.96, 0.95) };
    float t = clamp(h / 70, 0.0, 4.999);
    int i = int(t);
    return mix(stops[i], stops[i + 1], fract(t));
}

fragment float4 contoursFragment(LookVertexOut in [[stage_in]],
                                 texture2d<float> texture [[texture(0)]], sampler s [[sampler(0)]],
                                 constant LookDraw &draw [[buffer(0)]],
                                 constant LookFrame &frame [[buffer(1)]]) {
    float h = ellipsoidHeight(in.anchorPosition, frame);
    float shade = luminance(baseColour(in, texture, s, draw).rgb);
    float3 colour = srgbToLinear(hypsometric(h)) * (0.45 + 0.9 * sqrt(shade));
    float minor = lines(h, 5, 1.0), major = lines(h, 25, 2.0), index = lines(h, 125, 3.0);
    float3 ink = srgbToLinear(float3(0.45, 0.26, 0.12));
    colour = mix(colour, ink, max(max(minor * 0.55, major * 0.85), index));
    return float4(colour, 1);
}

fragment float4 contoursSky(float4 position [[position]]) {
    return float4(srgbToLinear(float3(0.96, 0.93, 0.85)), 1);
}

// MARK: Thermal

/// Black through purple, red and orange to white.
static float3 ironbow(float t) {
    t = saturate(t);
    const float3 stops[6] = { float3(0.0, 0.0, 0.05), float3(0.25, 0.0, 0.5), float3(0.75, 0.05, 0.45),
                              float3(1.0, 0.35, 0.0), float3(1.0, 0.8, 0.1), float3(1.0, 1.0, 0.9) };
    float x = t * 4.999;
    int i = int(x);
    return mix(stops[i], stops[i + 1], fract(x));
}

fragment float4 thermalFragment(LookVertexOut in [[stage_in]],
                                texture2d<float> texture [[texture(0)]], sampler s [[sampler(0)]],
                                constant LookDraw &draw [[buffer(0)]],
                                constant LookFrame &frame [[buffer(1)]]) {
    float3 p = in.anchorPosition;
    float lum = luminance(baseColour(in, texture, s, draw).rgb);
    // Sunlit roofs run hot, walls cooler; a slow shimmer moves over it all.
    float sun = saturate(faceNormal(p, frame).y);
    float time = frame.eyeTime.w;
    float shimmer = noise(p * 0.04 + float3(0, time * 0.3, 0)) - 0.5;
    float heat = 0.15 + 0.75 * sqrt(lum) + 0.25 * sun + 0.18 * shimmer;
    return float4(srgbToLinear(ironbow(heat)), 1);
}

fragment float4 thermalSky(float4 position [[position]]) {
    return float4(srgbToLinear(float3(0.02, 0.0, 0.07)), 1);
}

// MARK: Blueprint

fragment float4 blueprintFragment(LookVertexOut in [[stage_in]],
                                  float3 bary [[barycentric_coord]],
                                  texture2d<float> texture [[texture(0)]], sampler s [[sampler(0)]],
                                  constant LookDraw &draw [[buffer(0)]],
                                  constant LookFrame &frame [[buffer(1)]]) {
    float3 p = in.anchorPosition;
    float3 paper = srgbToLinear(float3(0.07, 0.25, 0.52));
    float3 chalk = srgbToLinear(float3(0.92, 0.96, 1.0));
    // Triangle edges, thinning out where triangles get only a few pixels
    // across (far away, or dense meshes) so it doesn't turn solid white.
    float3 w = fwidth(bary);
    float3 edge3 = 1 - smoothstep(w * 0.25, w * 1.25, bary);
    float edge = max(max(edge3.x, edge3.y), edge3.z) * saturate(1.3 - 3.5 * max(max(w.x, w.y), w.z));
    // Shaded faces, faintly, so the forms read.
    float3 n = faceNormal(p, frame);
    float face = 0.1 + 0.12 * saturate(dot(n, normalize(float3(0.4, 1, 0.3))));
    float shade = luminance(baseColour(in, texture, s, draw).rgb);
    float3 colour = paper * (0.85 + face + 0.25 * shade);
    colour = mix(colour, chalk, edge * 0.8);
    return float4(colour, 1);
}

struct ScreenOut {
    float4 position [[position]];
    float2 ndc;
};

/// One triangle covering the view at a fixed depth. Its interpolated NDC
/// is the logical position, rasterization-rate map or not.
vertex ScreenOut lookScreenVertex(uint vid [[vertex_id]], constant float &depth [[buffer(0)]]) {
    float2 corner = float2((vid << 1) & 2, vid & 2) * 2 - 1;
    ScreenOut out;
    out.position = float4(corner, depth, 1);
    out.ndc = corner;
    return out;
}

/// The view direction through a screen point, in the anchor frame.
static float3 viewDirection(float2 ndc, constant LookFrame &frame) {
    float4 near = frame.anchorFromClip * float4(ndc, 1, 1);
    return normalize(near.xyz / near.w - frame.eyeTime.xyz);
}

fragment float4 blueprintSky(ScreenOut in [[stage_in]], constant LookFrame &frame [[buffer(1)]]) {
    float3 d = viewDirection(in.ndc, frame);
    float3 paper = srgbToLinear(float3(0.05, 0.19, 0.42));
    // Graph paper on the sky: every 2° of heading and elevation.
    float heading = atan2(d.x, -d.z) * 57.29578, elevation = asin(clamp(d.y, -1.0, 1.0)) * 57.29578;
    float grid = max(lines(heading, 2, 1.0), lines(elevation, 2, 1.0)) * 0.12;
    return float4(mix(paper, float3(0.8, 0.9, 1.0), grid), 1);
}

// MARK: Tiny planet, Inside out

fragment float4 planetFragment(LookVertexOut in [[stage_in]],
                               texture2d<float> texture [[texture(0)]], sampler s [[sampler(0)]],
                               constant LookDraw &draw [[buffer(0)]]) {
    float4 colour = baseColour(in, texture, s, draw);
    // A little more saturated, like a toy.
    float lum = luminance(colour.rgb);
    colour.rgb = max(mix(float3(lum), colour.rgb, 1.35), 0.0);
    return colour;
}

fragment float4 planetSky(ScreenOut in [[stage_in]], constant LookFrame &frame [[buffer(1)]]) {
    float3 d = viewDirection(in.ndc, frame);
    // Space, with a thin blue atmosphere at the horizon and stars on a
    // grid of directions.
    float3 colour = mix(float3(0.0, 0.003, 0.02), srgbToLinear(float3(0.35, 0.55, 0.9)),
                        exp(-abs(d.y) * 9) * 0.6);
    float3 cell = floor(d * 220);
    float star = hash(cell);
    if (star > 0.985) {
        float glow = saturate(1 - length(d * 220 - floor(d * 220) - 0.5) * 2.2);
        colour += float3(0.9, 0.92, 1.0) * glow * glow * (star - 0.985) * 66;
    }
    return float4(colour, 1);
}

// MARK: Sonar

fragment float4 sonarFragment(LookVertexOut in [[stage_in]],
                              texture2d<float> texture [[texture(0)]], sampler s [[sampler(0)]],
                              constant LookDraw &draw [[buffer(0)]],
                              constant LookFrame &frame [[buffer(1)]]) {
    float3 p = in.anchorPosition;
    float3 eye = frame.eyeTime.xyz;
    float time = frame.eyeTime.w;
    float distance = length(p - eye);
    // Pulses scaled to how high the eye is, out and fading every 4 s.
    float range = max(abs(eye.y), 30.0) * 5;
    float period = 4;
    float front = fract(time / period) * range;
    float behind = front - distance;
    float wave = exp(-pow(behind / (range * 0.012), 2));
    float trail = behind > 0 ? exp(-behind / (range * 0.18)) : 0;
    float fade = 1 - fract(time / period);
    float lum = luminance(baseColour(in, texture, s, draw).rgb);
    float3 n = faceNormal(p, frame);
    // Faces turned towards the eye echo more strongly.
    float facing = saturate(dot(n, normalize(eye - p)));
    float echo = (0.35 + 0.65 * facing) * (0.4 + 0.9 * lum);
    float rings = lines(distance, range / 10, 1.0) * 0.25;
    float3 phosphor = float3(0.15, 1.0, 0.35);
    float3 colour = phosphor * (0.025 * (0.5 + lum) + rings * 0.5 + echo * trail * 0.8 * fade)
                  + float3(0.7, 1.0, 0.8) * wave * fade;
    return float4(colour, 1);
}

fragment float4 sonarSky(ScreenOut in [[stage_in]]) {
    return float4(0, 0.004, 0.002, 1);
}

// MARK: Halftone

/// A direction as a face of a cube around the anchor and equal-angle
/// coordinates on it, from -pi/4 to pi/4. The screen is printed on this
/// cube, fixed to the world, so dots stay put as the head turns, and,
/// being at infinity, line up between the eyes.
static float2 cubeFace(float3 d) {
    float3 a = abs(d);
    float2 uv = a.x >= max(a.y, a.z) ? d.yz / a.x : a.y >= a.z ? d.xz / a.y : d.xy / a.z;
    return atan(uv);
}

/// One ink's dot screen on a cube face: a square grid of `cell` radians,
/// rounded so a whole number fits each face, plus dots on its corners when
/// `diagonal` (a 45° screen). Either way the dots meet across the cube's
/// edges. Each dot covers `amount` of its cell.
static float dots(float2 uv, float amount, float cell, bool diagonal) {
    float quarter = M_PI_F / 2;
    float size = quarter / max(1.0, round(quarter / cell));
    float2 offset = fract((uv + quarter / 2) / size) - 0.5;
    float distance = length(offset);
    float pitch = 1;
    if (diagonal) {
        distance = min(distance, length(abs(offset) - 0.5));
        pitch = M_SQRT1_2_F;
    }
    float radius = sqrt(saturate(amount)) * 0.56 * pitch;
    float edge = fwidth(distance) + 1e-4;
    return 1 - smoothstep(radius - edge, radius + edge, distance);
}

/// Reads the finished pixel (sky and tiles) and prints it like a
/// newspaper photo: black dots on a 45° screen, a sparse red screen for
/// warm colours, on newsprint.
fragment float4 halftonePost(ScreenOut in [[stage_in]], float4 finished [[color(0)]],
                             constant LookFrame &frame [[buffer(1)]]) {
    float2 uv = cubeFace(viewDirection(in.ndc, frame));
    float3 rgb = pow(saturate(finished.rgb), 1 / 2.2);
    float tone = luminance(rgb);
    // Contrast stretched a little, as a press would.
    float black = dots(uv, saturate((0.92 - tone) * 1.25), 0.0113, true);
    float warmth = saturate((rgb.r - max(rgb.g, rgb.b)) * 3 + (rgb.r + rgb.g - 2 * rgb.b) * 0.8);
    float red = dots(uv, warmth * 0.7, 0.0104, false);
    float3 paper = float3(0.95, 0.92, 0.84);
    float3 printed = paper * (1 - red * float3(0.05, 0.75, 0.7)) * (1 - black * 0.9);
    // Premultiplied, so a transparent sky (mixed immersion) stays clear.
    return float4(srgbToLinear(printed) * finished.a, finished.a);
}
"""
}
