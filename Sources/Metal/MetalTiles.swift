import Foundation
import Metal
import OSLog
import simd

/// A Metal renderer for streamed tiles (experimental): the same seam
/// as the RealityKit path, without RealityKit. Each loaded tile gets Metal
/// buffers and a texture, built off the main thread by `handler` before
/// cesium-native counts it as loaded; `encode` draws a frame's tiles into a
/// colour and depth target. Depth is reverse Z (1 near, 0 far), cleared to 0.
///
/// Used when Settings › General › Draw with Metal is on
/// (ViewPreferences.drawsWithMetal): for the map window on macOS and iOS
/// (MetalMapView), and for the immersive mode on visionOS
/// (MetalImmersiveContent). Tracks and tile bounds aren't drawn.
final class MetalTileRenderer: @unchecked Sendable {
    /// Made on first use; nil if Metal isn't available.
    static let shared: MetalTileRenderer? = {
        do {
            return try MetalTileRenderer()
        } catch {
            print("[AlsoMaps] Metal renderer unavailable: \(error)")
            return nil
        }
    }()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private let depthState: MTLDepthStencilState
    /// Sampler states by glTF sampler, shared between tiles.
    private var samplers: [SIMD4<Int>: MTLSamplerState] = [:]
    private let samplersLock = NSLock()
    /// Pipelines by colour and depth format and kind (tiles, fading tiles,
    /// or the depth-only sky pass), made on first use.
    private var pipelines: [SIMD3<UInt>: MTLRenderPipelineState] = [:]
    private let pipelinesLock = NSLock()
    /// A/B switch for device profiling; only draw submission changes.
    private let cullsOffscreen = ProcessInfo.processInfo.environment["ALSOMAPS_METAL_CULLING"] != "0"
    /// `ALSOMAPS_METAL_FOG=0` turns the distance fog and edge fade off.
    private let drawsFog = ProcessInfo.processInfo.environment["ALSOMAPS_METAL_FOG"] != "0"

    /// The sky, as in ScreenMapView, as an sRGB target's clear colour (linear).
    static let skyColour = MTLClearColor(red: pow(0.55, 2.2), green: pow(0.7, 2.2), blue: pow(0.85, 2.2), alpha: 1)

    enum MetalError: Error { case noDevice, setup }

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw MetalError.noDevice }
        self.device = device
        // Compiled at launch from source: building .metal files needs Xcode's
        // separately installed Metal Toolchain.
        library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = true
        guard let queue = device.makeCommandQueue(),
              let depthState = device.makeDepthStencilState(descriptor: depth)
        else { throw MetalError.setup }
        self.queue = queue
        self.depthState = depthState
    }

    // MARK: Tiles

    /// A tile's GPU resources, attached as its `renderObject`.
    final class Tile: @unchecked Sendable {
        struct Part {
            let bounds: MetalBounds?
            let positions: MTLBuffer
            let texcoords: MTLBuffer?
            let normals: MTLBuffer?
            let indices: MTLBuffer
            let indexCount: Int
            let texture: MTLTexture?
            let sampler: MTLSamplerState?
            let baseColor: SIMD4<Float>
            /// For untextured content in a tileset with imagery: where each
            /// vertex falls in the tile's overlay (CNPrimitive.overlayTexcoords).
            let overlayTexcoords: MTLBuffer?
        }
        let parts: [Part]
        let bounds: MetalBounds?
        let triangleCount: Int
        /// The imagery last drawn on this tile, kept until a newer
        /// attachment's texture is ready. Only `encode` touches it.
        var shownOverlay: CNOverlay?
        init(parts: [Part]) {
            self.parts = parts
            // An unknown part must not be hidden by a known part's bounds.
            bounds = parts.reduce(parts.first?.bounds) { combined, part in
                guard let combined, let bounds = part.bounds else { return nil }
                return combined.union(bounds)
            }
            triangleCount = parts.reduce(0) { $0 + $1.indexCount / 3 }
        }
    }

    /// Tile builds running now, for the MetalBuild signpost.
    private let buildsInFlight = OSAllocatedUnfairLock(initialState: 0)

    var handler: CNTileLoadHandler {
        { [self] tile, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let signposter = Signposts.tiles
                let inFlight = self.buildsInFlight.withLock { count in
                    count += 1
                    return count
                }
                let interval = signposter.beginInterval("MetalBuild", id: signposter.makeSignpostID(),
                                                        "\(inFlight) in flight")
                tile.renderObject = self.build(tile)
                tile.discardCPUData()
                self.buildsInFlight.withLock { $0 -= 1 }
                signposter.endInterval("MetalBuild", interval)
                completion()
            }
        }
    }

    private func build(_ tile: CNTileMesh) -> Tile {
        var parts: [Tile.Part] = []
        for primitive in tile.primitives ?? [] {
            guard let positions = buffer(primitive.positions), let indices = buffer(primitive.indices) else { continue }
            parts.append(Tile.Part(bounds: MetalBounds(positions: primitive.positions), positions: positions,
                                   texcoords: primitive.texcoords.flatMap(buffer),
                                   normals: primitive.normals.flatMap(buffer),
                                   indices: indices,
                                   indexCount: primitive.indices.count / MemoryLayout<UInt32>.size,
                                   texture: texture(for: primitive),
                                   sampler: sampler(for: primitive),
                                   baseColor: primitive.baseColor,
                                   overlayTexcoords: primitive.texcoords == nil
                                       ? primitive.overlayTexcoords.flatMap(buffer) : nil))
        }
        return Tile(parts: parts)
    }

    /// Builds each overlay image's texture (CNTileStreamer.rasterLoadHandler),
    /// on the calling load thread: nothing waits for it.
    var rasterHandler: CNRasterLoadHandler {
        { [self] raster in
            raster.renderObject = texture(rgba: raster.rgba, width: raster.width, height: raster.height)
            raster.discardCPUData()
        }
    }

    /// Terrain waiting for its imagery, briefly (as TileUploader).
    private static let overlayPlaceholderColor = SIMD4<Float>(0.30, 0.33, 0.24, 1)

    /// Clamped, so an overlay image's edge doesn't bleed in from the
    /// opposite side; trilinear.
    private lazy var overlaySampler: MTLSamplerState? = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        return device.makeSamplerState(descriptor: descriptor)
    }()

    private func buffer(_ data: Data) -> MTLBuffer? {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
    }

    /// The primitive's glTF sampler (TileUploader's mapping, as RealityKit
    /// uses), made once per distinct sampler.
    private func sampler(for primitive: CNPrimitive) -> MTLSamplerState? {
        let key = SIMD4(primitive.textureWrapS, primitive.textureWrapT,
                        primitive.textureMagFilter, primitive.textureMinFilter)
        samplersLock.lock()
        defer { samplersLock.unlock() }
        if let sampler = samplers[key] { return sampler }
        let sampler = device.makeSamplerState(descriptor: TileUploader.samplerDescriptor(for: primitive))
        samplers[key] = sampler
        return sampler
    }

    /// sRGB, mipmapped. The bridge's RGBA rows start at the image's top, as
    /// Metal's texture origin does.
    private func texture(for primitive: CNPrimitive) -> MTLTexture? {
        guard let rgba = primitive.rgba else { return nil }
        return texture(rgba: rgba, width: primitive.textureWidth, height: primitive.textureHeight)
    }

    private func texture(rgba: Data, width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width,
                                                                  height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        rgba.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: base, bytesPerRow: width * 4)
        }
        if texture.mipmapLevelCount > 1, let commands = queue.makeCommandBuffer(),
           let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        return texture
    }

    // MARK: Drawing

    /// Must match TileUniforms in `shaderSource`.
    private struct Uniforms {
        var modelViewProjection: simd_float4x4
        var model: simd_float4x4
        /// Tile → anchor frame, for fog.
        var placement: simd_float4x4
        var baseColor: SIMD4<Float>
        /// Overlay texture coordinates → image: xy translation, zw scale.
        var overlayTransform: SIMD4<Float>
        var flags: UInt32
        /// How far the tile has faded in (MetalTileFades), 0–1.
        var visibility: Float
    }

    /// Must match Atmosphere in `shaderSource`. Fog in the anchor frame, so
    /// it's the same in a window and in the immersive space at any scale.
    private struct Atmosphere {
        /// xyz: the camera in the anchor frame; w: 1 if fog is on.
        var camera: SIMD4<Float>
        /// The sky, linear and premultiplied.
        var colour: SIMD4<Float>
        /// The area of interest's right and forward axes (xz), and its
        /// half-width, metres.
        var right: SIMD2<Float>
        var forward: SIMD2<Float>
        var radius: Float
        /// Distance over which haze builds, metres.
        var hazeDistance: Float
    }

    /// The streamed area, for fog: tiles thin out toward its edge, and
    /// stop beyond it, so the far edge fades into the sky.
    struct Region {
        /// Half-width of the area-of-interest square, anchor-frame metres.
        var radius: Double
        /// Radians clockwise from north.
        var heading: Double
        /// What fog fades to: the pass's clear colour. Transparent black over
        /// passthrough (premultiplied), so the map fades into the room.
        var sky: MTLClearColor

        init(_ inputs: StreamingInputs, sky: MTLClearColor = MetalTileRenderer.skyColour) {
            radius = inputs.streamingRadius
            heading = inputs.regionHeading
            self.sky = sky
        }
    }

    private enum PipelineKind: UInt { case tiles, fadingTiles, skyDepth }

    private func pipeline(colour: MTLPixelFormat, depth: MTLPixelFormat,
                          kind: PipelineKind = .tiles) -> MTLRenderPipelineState? {
        let skyDepth = kind == .skyDepth
        let key = SIMD3(colour.rawValue, depth.rawValue, kind.rawValue)
        pipelinesLock.lock()
        defer { pipelinesLock.unlock() }
        if let pipeline = pipelines[key] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        if skyDepth {
            // Depth only: the colour already there (sky or tiles) stays.
            descriptor.vertexFunction = library.makeFunction(name: "skyDepthVertex")
            descriptor.colorAttachments[0].writeMask = []
        } else {
            descriptor.vertexFunction = library.makeFunction(name: "tileVertex")
            // Discarding only in the fading variant keeps hidden-surface
            // removal fully effective for the settled tiles.
            let constants = MTLFunctionConstantValues()
            var dithered = kind == .fadingTiles
            constants.setConstantValue(&dithered, type: .bool, index: 0)
            do {
                descriptor.fragmentFunction = try library.makeFunction(name: "tileFragment", constantValues: constants)
            } catch {
                print("[AlsoMaps] Metal fragment function failed: \(error)")
                return nil
            }
        }
        descriptor.colorAttachments[0].pixelFormat = colour
        descriptor.depthAttachmentPixelFormat = depth
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = pipeline
            return pipeline
        } catch {
            print("[AlsoMaps] Metal pipeline failed: \(error)")
            return nil
        }
    }

    /// Draws `tiles` (each placed in the anchor's frame) after `root` (anchor
    /// frame → scene) and `viewProjection` (scene → clip, reverse Z). With
    /// `fades`, new tiles dissolve in and tiles no longer drawn dissolve out
    /// (MetalTileFades); with `region`, distance fog and the area's edge fade
    /// toward the sky.
    @discardableResult
    func encode(_ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat,
                viewProjection: simd_float4x4, root: simd_float4x4,
                tiles: [(tile: CNTileMesh, placement: simd_float4x4)],
                fades: MetalTileFades? = nil, region: Region? = nil) -> MetalDrawStatistics {
        let signposter = Signposts.frame
        let interval = signposter.beginInterval("MetalEncode", id: signposter.makeSignpostID())
        defer { signposter.endInterval("MetalEncode", interval) }
        var statistics = MetalDrawStatistics()
        guard let settled = pipeline(colour: colour, depth: depth),
              let fading = pipeline(colour: colour, depth: depth, kind: .fadingTiles)
        else { return statistics }
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        let rootViewProjection = viewProjection * root

        var atmosphere = Atmosphere(camera: .zero, colour: SIMD4(Float(Self.skyColour.red), Float(Self.skyColour.green),
                                                                  Float(Self.skyColour.blue), 1),
                                    right: SIMD2(1, 0), forward: SIMD2(0, -1), radius: 1, hazeDistance: 1)
        if drawsFog, let region, region.radius > 0 {
            // The camera is the point the projection sends to w = 0 at the
            // origin of clip x and y.
            let camera = rootViewProjection.inverse * SIMD4<Float>(0, 0, 1, 0)
            if camera.w != 0 {
                atmosphere.camera = SIMD4(camera.x / camera.w, camera.y / camera.w, camera.z / camera.w, 1)
                let s = Float(sin(region.heading)), c = Float(cos(region.heading))
                // Anchor frame: x east, z south.
                atmosphere.forward = SIMD2(s, -c)
                atmosphere.right = SIMD2(c, s)
                atmosphere.radius = Float(region.radius)
                atmosphere.colour = SIMD4(Float(region.sky.red), Float(region.sky.green),
                                          Float(region.sky.blue), Float(region.sky.alpha))
                // Haze scales with how far the camera can see: the horizon
                // from its height above the anchor, at least 20 km so street
                // level isn't murky, and at most the area, so a small
                // area (the immersive map) hazes before its edge.
                let height = Double(max(atmosphere.camera.y, 0))
                let horizon = (2 * 6_371_000 * height).squareRoot()
                atmosphere.hazeDistance = Float(min(max(horizon, 20_000), region.radius))
            }
        }
        encoder.setFragmentBytes(&atmosphere, length: MemoryLayout<Atmosphere>.stride, index: 1)

        func draw(_ tile: CNTileMesh, _ gpu: Tile, placement: simd_float4x4, visibility: Float, fadingOut: Bool) {
            statistics.tiles += 1
            statistics.totalDrawCalls += gpu.parts.count
            statistics.totalTriangles += gpu.triangleCount
            let modelViewProjection = rootViewProjection * placement
            let frustum = cullsOffscreen ? MetalFrustum(clipFromLocal: modelViewProjection) : nil
            if frustum?.intersects(gpu.bounds) == false { return }
            let model = root * placement
            // Newly attached imagery replaces the old once its texture is
            // ready; until then the old stays.
            if let overlay = tile.overlay, overlay !== gpu.shownOverlay, overlay.raster.renderObject is MTLTexture {
                gpu.shownOverlay = overlay
            }
            let overlay = gpu.shownOverlay
            let overlayTexture = overlay?.raster.renderObject as? MTLTexture
            var drewTile = false
            for part in gpu.parts {
                // A tile may straddle the frustum while some of its parts
                // are wholly outside. Single-part tiles were tested above.
                if gpu.parts.count > 1, frustum?.intersects(part.bounds) == false { continue }
                if !drewTile {
                    statistics.submittedTiles += 1
                    drewTile = true
                }
                statistics.drawCalls += 1
                statistics.triangles += part.indexCount / 3
                var flags: UInt32 = 0
                var texcoords = part.texcoords
                var texture = part.texture
                var sampler = part.sampler
                var baseColor = part.baseColor
                var overlayTransform = SIMD4<Float>(0, 0, 1, 1)
                if let overlay, let overlayTexture, let overlayTexcoords = part.overlayTexcoords {
                    // Imagery on terrain: unlit, like photogrammetry, since
                    // aerial imagery has its lighting baked in.
                    texcoords = overlayTexcoords
                    texture = overlayTexture
                    sampler = overlaySampler
                    baseColor = SIMD4(1, 1, 1, 1)
                    overlayTransform = SIMD4(lowHalf: SIMD2(overlay.translation), highHalf: SIMD2(overlay.scale))
                    flags |= 1 | 4
                } else {
                    if part.texcoords != nil, part.texture != nil { flags |= 1 }
                    if part.normals != nil { flags |= 2 }
                    if part.overlayTexcoords != nil { baseColor = Self.overlayPlaceholderColor }
                }
                if fadingOut { flags |= 8 }
                var uniforms = Uniforms(modelViewProjection: modelViewProjection, model: model, placement: placement,
                                        baseColor: baseColor, overlayTransform: overlayTransform, flags: flags,
                                        visibility: visibility)
                encoder.setVertexBuffer(part.positions, offset: 0, index: 0)
                encoder.setVertexBuffer(texcoords ?? part.positions, offset: 0, index: 1)
                encoder.setVertexBuffer(part.normals ?? part.positions, offset: 0, index: 2)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32,
                                              indexBuffer: part.indices, indexBufferOffset: 0)
            }
        }

        // Settled tiles first, then the dissolving ones with the discarding
        // pipeline. A tile fading out draws the complement of the pattern,
        // so it and what replaced it share no pixel.
        var dissolving: [(tile: CNTileMesh, gpu: Tile, placement: simd_float4x4, visibility: Float, out: Bool)] = []
        encoder.setRenderPipelineState(settled)
        for (tile, placement) in tiles {
            guard let gpu = tile.renderObject as? Tile else { continue }
            let visibility = fades?.visibility(of: tile) ?? 1
            if visibility < 1 {
                dissolving.append((tile, gpu, placement, visibility, false))
            } else {
                draw(tile, gpu, placement: placement, visibility: 1, fadingOut: false)
            }
        }
        for leaving in fades.map({ Array($0.leaving.values) }) ?? [] {
            guard let gpu = leaving.tile.renderObject as? Tile else { continue }
            dissolving.append((leaving.tile, gpu, leaving.placement, leaving.visibility, true))
        }
        if !dissolving.isEmpty {
            encoder.setRenderPipelineState(fading)
            for item in dissolving {
                draw(item.tile, item.gpu, placement: item.placement, visibility: item.visibility, fadingOut: item.out)
            }
        }
        return statistics
    }

    /// The sky's depth for a compositor: just inside the far plane. A
    /// compositor drops pixels at the far plane itself (depth 0 in reverse
    /// Z) as clipped, which in full immersion shows black where there's only
    /// sky. With an infinite far plane and 0.1 m near, about 100 km away.
    static let skyDepth: Float = 1e-6

    /// After the tiles, moves every pixel still at the far plane (the sky)
    /// to `skyDepth`, leaving colour alone. Tiles farther than that keep
    /// their colour and only have their depth raised, so nothing is hidden.
    /// Only a compositor needs it: a window shows the cleared sky as is.
    func encodeSkyDepth(_ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat) {
        guard let pipeline = pipeline(colour: colour, depth: depth, kind: .skyDepth) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        var depth = Self.skyDepth
        encoder.setVertexBytes(&depth, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// Must match MetalTileRenderer.Uniforms.
struct TileUniforms {
    float4x4 modelViewProjection;
    float4x4 model;
    float4x4 placement;
    float4 baseColor;
    float4 overlayTransform;
    uint flags;
    float visibility;
};

// Must match MetalTileRenderer.Atmosphere.
struct Atmosphere {
    float4 camera;
    float4 colour;
    float2 right;
    float2 forward;
    float radius;
    float hazeDistance;
};

constant uint kTextured = 1;
constant uint kLit = 2;
constant uint kOverlay = 4;
constant uint kFadingOut = 8;

/// The fading pipeline: discards a screen-space pattern (MetalTileFades).
constant bool kDithered [[function_constant(0)]];

struct TileVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 normal;
    float3 anchorPosition;
};

/// Positions are float4 (xyz + padding) offsets from the tile's centre; the
/// bridge flips v for RealityKit, so it's flipped back for Metal's top-left
/// texture origin.
vertex TileVertexOut tileVertex(uint vid [[vertex_id]],
                                const device float4 *positions [[buffer(0)]],
                                const device float2 *texcoords [[buffer(1)]],
                                const device float4 *normals [[buffer(2)]],
                                constant TileUniforms &uniforms [[buffer(3)]]) {
    TileVertexOut out;
    out.position = uniforms.modelViewProjection * float4(positions[vid].xyz, 1);
    float2 uv = texcoords[vid];
    if (uniforms.flags & kOverlay) {
        // Overlay coordinates have v up, like the bridge's flipped ones.
        uv = uv * uniforms.overlayTransform.zw + uniforms.overlayTransform.xy;
    }
    out.uv = (uniforms.flags & kTextured) ? float2(uv.x, 1 - uv.y) : float2(0);
    out.normal = (uniforms.flags & kLit) ? (uniforms.model * float4(normals[vid].xyz, 0)).xyz : float3(0, 1, 0);
    out.anchorPosition = (uniforms.placement * float4(positions[vid].xyz, 1)).xyz;
    return out;
}

/// A fixed per-pixel threshold in [0, 1) (interleaved gradient noise): a
/// fine, even dissolve with many levels. Fixed, so a tile fading in and the
/// one it replaces fading out use the same pattern in the same frame.
static float ditherThreshold(float2 pixel) {
    return fract(52.9829189 * fract(dot(floor(pixel), float2(0.06711056, 0.00583715))));
}

/// Unlit photogrammetry (its lighting is baked in), or untextured content
/// shaded by a light from above.
fragment float4 tileFragment(TileVertexOut in [[stage_in]],
                             texture2d<float> texture [[texture(0)]],
                             sampler textureSampler [[sampler(0)]],
                             constant TileUniforms &uniforms [[buffer(0)]],
                             constant Atmosphere &atmosphere [[buffer(1)]]) {
    if (kDithered) {
        // In: drawn where the threshold is under its visibility. Out: the
        // complement of a tile at 1 - visibility, which is what replaced it.
        float threshold = ditherThreshold(in.position.xy);
        bool shown = (uniforms.flags & kFadingOut) ? threshold >= 1 - uniforms.visibility
                                                   : threshold < uniforms.visibility;
        if (!shown) discard_fragment();
    }
    float4 colour = uniforms.baseColor;
    if (uniforms.flags & kTextured) {
        colour *= texture.sample(textureSampler, in.uv);
    }
    if (uniforms.flags & kLit) {
        float light = max(dot(normalize(in.normal), normalize(float3(0.3, 1, 0.2))), 0.0);
        colour.rgb *= 0.55 + 0.45 * light;
    }
    if (atmosphere.camera.w > 0) {
        // Haze with distance, reaching the sky at the area's edge, where
        // detail is coarsest; and the edge itself, so the square the tiles
        // stop at isn't seen.
        float3 p = in.anchorPosition;
        float distance = length(p - atmosphere.camera.xyz) / atmosphere.hazeDistance;
        float haze = 0.9 * (1 - exp(-1.5 * distance));
        float edge = max(abs(dot(p.xz, atmosphere.right)), abs(dot(p.xz, atmosphere.forward))) / atmosphere.radius;
        float fog = max(haze, smoothstep(0.75, 1.0, edge));
        // All four channels: over passthrough the sky is transparent, and
        // colour is premultiplied.
        colour = mix(colour, atmosphere.colour, fog);
    }
    return colour;
}

struct SkyDepthOut {
    float4 position [[position]];
};

/// One triangle covering the view, at a fixed depth (encodeSkyDepth).
vertex SkyDepthOut skyDepthVertex(uint vid [[vertex_id]], constant float &depth [[buffer(0)]]) {
    float2 corner = float2((vid << 1) & 2, vid & 2);
    SkyDepthOut out;
    out.position = float4(corner * 2 - 1, depth, 1);
    return out;
}
"""
}
