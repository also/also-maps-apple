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
    /// Pipelines by colour and depth format and kind (tiles, or the
    /// depth-only sky pass), made on first use.
    private var pipelines: [SIMD3<UInt>: MTLRenderPipelineState] = [:]
    private let pipelinesLock = NSLock()
    /// A/B switch for device profiling; only draw submission changes.
    private let cullsOffscreen = ProcessInfo.processInfo.environment["ALSOMAPS_METAL_CULLING"] != "0"

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
        }
        let parts: [Part]
        let bounds: MetalBounds?
        let triangleCount: Int
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
                                   baseColor: primitive.baseColor))
        }
        return Tile(parts: parts)
    }

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
        guard let rgba = primitive.rgba, primitive.textureWidth > 0, primitive.textureHeight > 0 else { return nil }
        let width = primitive.textureWidth, height = primitive.textureHeight
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
        var baseColor: SIMD4<Float>
        var flags: UInt32
    }

    private func pipeline(colour: MTLPixelFormat, depth: MTLPixelFormat,
                          skyDepth: Bool = false) -> MTLRenderPipelineState? {
        let key = SIMD3(colour.rawValue, depth.rawValue, skyDepth ? 1 : 0)
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
            descriptor.fragmentFunction = library.makeFunction(name: "tileFragment")
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
    /// frame → scene) and `viewProjection` (scene → clip, reverse Z).
    @discardableResult
    func encode(_ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat,
                viewProjection: simd_float4x4, root: simd_float4x4,
                tiles: [(tile: CNTileMesh, placement: simd_float4x4)]) -> MetalDrawStatistics {
        let signposter = Signposts.frame
        let interval = signposter.beginInterval("MetalEncode", id: signposter.makeSignpostID())
        defer { signposter.endInterval("MetalEncode", interval) }
        var statistics = MetalDrawStatistics()
        guard let pipeline = pipeline(colour: colour, depth: depth) else { return statistics }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        let rootViewProjection = viewProjection * root
        for (tile, placement) in tiles {
            guard let gpu = tile.renderObject as? Tile else { continue }
            statistics.tiles += 1
            statistics.totalDrawCalls += gpu.parts.count
            statistics.totalTriangles += gpu.triangleCount
            let modelViewProjection = rootViewProjection * placement
            let frustum = cullsOffscreen ? MetalFrustum(clipFromLocal: modelViewProjection) : nil
            if frustum?.intersects(gpu.bounds) == false { continue }
            let model = root * placement
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
                if part.texcoords != nil, part.texture != nil { flags |= 1 }
                if part.normals != nil { flags |= 2 }
                var uniforms = Uniforms(modelViewProjection: modelViewProjection, model: model,
                                        baseColor: part.baseColor, flags: flags)
                encoder.setVertexBuffer(part.positions, offset: 0, index: 0)
                encoder.setVertexBuffer(part.texcoords ?? part.positions, offset: 0, index: 1)
                encoder.setVertexBuffer(part.normals ?? part.positions, offset: 0, index: 2)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(part.texture, index: 0)
                encoder.setFragmentSamplerState(part.sampler, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32,
                                              indexBuffer: part.indices, indexBufferOffset: 0)
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
    func encodeSkyDepth(_ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat,
                        at value: Float = skyDepth) {
        guard let pipeline = pipeline(colour: colour, depth: depth, skyDepth: true) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        var depth = value
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
    float4 baseColor;
    uint flags;
};

constant uint kTextured = 1;
constant uint kLit = 2;

struct TileVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 normal;
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
    out.uv = (uniforms.flags & kTextured) ? float2(texcoords[vid].x, 1 - texcoords[vid].y) : float2(0);
    out.normal = (uniforms.flags & kLit) ? (uniforms.model * float4(normals[vid].xyz, 0)).xyz : float3(0, 1, 0);
    return out;
}

/// Unlit photogrammetry (its lighting is baked in), or untextured content
/// shaded by a light from above.
fragment float4 tileFragment(TileVertexOut in [[stage_in]],
                             texture2d<float> texture [[texture(0)]],
                             sampler textureSampler [[sampler(0)]],
                             constant TileUniforms &uniforms [[buffer(0)]]) {
    float4 colour = uniforms.baseColor;
    if (uniforms.flags & kTextured) {
        colour *= texture.sample(textureSampler, in.uv);
    }
    if (uniforms.flags & kLit) {
        float light = max(dot(normalize(in.normal), normalize(float3(0.3, 1, 0.2))), 0.0);
        colour.rgb *= 0.55 + 0.45 * light;
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
