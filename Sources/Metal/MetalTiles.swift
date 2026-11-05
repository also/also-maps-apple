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
///
/// With a `Lighting` (the clay and sun study, SunStudy), tiles are drawn by
/// a second fragment function instead: clay or textured, lit by the sun,
/// with shadows from a depth pass rendered from the sun once per frame
/// (`prepare`), and the day's sun path drawn as dots (`encodeSunPath`).
/// Without one, drawing is exactly as before.
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
    /// The shadow pass: regular Z from the sun, nearest wins.
    private let shadowDepthState: MTLDepthStencilState
    /// Shadow maps by size, reused frame to frame. Each frame's shadow
    /// pass and the draws that read it are in one command buffer, and Metal
    /// tracks hazards on textures made from the device by default, so a
    /// frame's write waits for the last frame's reads.
    private var shadowMaps: [Int: MTLTexture] = [:]
    private let shadowMapsLock = NSLock()
    /// Bound in place of a shadow map when there isn't one, so the study
    /// shader's texture argument is never unbound.
    private let emptyShadowMap: MTLTexture
    /// Sampler states by glTF sampler, shared between tiles.
    private var samplers: [SIMD4<Int>: MTLSamplerState] = [:]
    private let samplersLock = NSLock()
    /// Pipelines by colour and depth format and kind (tiles, or the
    /// depth-only sky pass), made on first use.
    private var pipelines: [SIMD3<UInt>: MTLRenderPipelineState] = [:]
    private enum PipelineKind: UInt {
        /// Tiles as they always were.
        case tiles
        /// The depth-only sky pass.
        case skyDepth
        /// Tiles lit by the sun study.
        case studyTiles
        /// Depth from the sun, no colour.
        case shadow
        /// The sun path's dots.
        case sunPath
    }
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
        let shadowDepth = MTLDepthStencilDescriptor()
        shadowDepth.depthCompareFunction = .less
        shadowDepth.isDepthWriteEnabled = true
        let empty = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1,
                                                             mipmapped: false)
        empty.usage = .shaderRead
        empty.storageMode = .private
        guard let queue = device.makeCommandQueue(),
              let depthState = device.makeDepthStencilState(descriptor: depth),
              let shadowDepthState = device.makeDepthStencilState(descriptor: shadowDepth),
              let emptyShadowMap = device.makeTexture(descriptor: empty)
        else { throw MetalError.setup }
        self.queue = queue
        self.depthState = depthState
        self.shadowDepthState = shadowDepthState
        self.emptyShadowMap = emptyShadowMap
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
        /// Tile → anchor frame (the placement), for the sun study's lighting.
        var anchorFromLocal: simd_float4x4
        var baseColor: SIMD4<Float>
        var flags: UInt32
    }

    private func pipeline(colour: MTLPixelFormat, depth: MTLPixelFormat,
                          kind: PipelineKind = .tiles) -> MTLRenderPipelineState? {
        let key = SIMD3(colour.rawValue, depth.rawValue, kind.rawValue)
        pipelinesLock.lock()
        defer { pipelinesLock.unlock() }
        if let pipeline = pipelines[key] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        switch kind {
        case .skyDepth:
            // Depth only: the colour already there (sky or tiles) stays.
            descriptor.vertexFunction = library.makeFunction(name: "skyDepthVertex")
            descriptor.colorAttachments[0].writeMask = []
        case .tiles:
            descriptor.vertexFunction = library.makeFunction(name: "tileVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "tileFragment")
        case .studyTiles:
            descriptor.vertexFunction = library.makeFunction(name: "tileVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "studyFragment")
        case .shadow:
            // No fragment function and no colour attachment: depth only.
            descriptor.vertexFunction = library.makeFunction(name: "shadowVertex")
        case .sunPath:
            descriptor.vertexFunction = library.makeFunction(name: "sunPathVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "sunPathFragment")
        }
        if kind != .shadow { descriptor.colorAttachments[0].pixelFormat = colour }
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
    /// With `lighting` (from `prepare`), lit by the sun study; `eye` is
    /// then the viewer's position in the scene, which the study's flat
    /// normals face.
    @discardableResult
    func encode(_ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat,
                viewProjection: simd_float4x4, root: simd_float4x4,
                tiles: [(tile: CNTileMesh, placement: simd_float4x4)],
                lighting: PreparedLighting? = nil, eye: SIMD3<Float> = .zero) -> MetalDrawStatistics {
        let signposter = Signposts.frame
        let interval = signposter.beginInterval("MetalEncode", id: signposter.makeSignpostID())
        defer { signposter.endInterval("MetalEncode", interval) }
        var statistics = MetalDrawStatistics()
        guard let pipeline = pipeline(colour: colour, depth: depth, kind: lighting == nil ? .tiles : .studyTiles)
        else { return statistics }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        if let lighting {
            var light = lighting.uniforms
            let anchorEye = root.inverse * SIMD4(eye, 1)
            light.eye = SIMD4(SIMD3(anchorEye.x, anchorEye.y, anchorEye.z) / anchorEye.w, 1)
            encoder.setFragmentBytes(&light, length: MemoryLayout<LightUniforms>.stride, index: 1)
            encoder.setFragmentTexture(lighting.shadowMap ?? emptyShadowMap, index: 1)
        }
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
                                        anchorFromLocal: placement, baseColor: part.baseColor, flags: flags)
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

    // MARK: Sun study

    /// The clay and sun study's look for a frame (built by SunStudy), in
    /// the anchor frame (x east, y up, z south, metres).
    struct Lighting {
        /// Matte untextured model instead of the photographs.
        var clay = false
        /// Render a shadow map from the sun and darken what it can't see.
        var shadows = false
        /// Apply shadows to textured tiles too (not only in clay).
        var shadowsOverTextures = false
        /// Unit, toward the sun.
        var toSun = SIMD3<Float>(0, 1, 0)
        /// 0 with the sun below the horizon, 1 in full daylight.
        var sunStrength: Float = 1
        /// Linear RGB.
        var sunColour = SIMD3<Float>(repeating: 0.85)
        var skyColour = SIMD3<Float>(repeating: 0.35)
        var groundColour = SIMD3<Float>(repeating: 0.15)
        var clayColour = SIMD3<Float>(0.8, 0.78, 0.74)
        /// How much light shadowed textured surfaces keep.
        var shadowedBrightness: Float = 0.55
        /// The ground the shadow map covers: a disc around this centre.
        var shadowCentre = SIMD3<Double>.zero
        var shadowRadius = 1000.0
        var shadowResolution = 2048
        /// The day's sun path, as dots in the anchor frame.
        var sunPath: [SunPathDot] = []
        /// The clear colour for the sky behind everything, linear.
        var clearColour = MetalTileRenderer.skyColour
    }

    /// Must match SunPathDot in `shaderSource`.
    struct SunPathDot {
        /// xyz in the anchor frame; w is the dot's radius as a fraction of
        /// the view's height.
        var position: SIMD4<Float>
        /// Linear RGBA.
        var colour: SIMD4<Float>
    }

    /// Must match LightUniforms in `shaderSource`.
    fileprivate struct LightUniforms {
        var shadowFromAnchor = matrix_identity_float4x4
        /// xyz toward the sun; w its strength.
        var toSun = SIMD4<Float>.zero
        /// The viewer in the anchor frame, set per view by `encode`.
        var eye = SIMD4<Float>.zero
        var sunColour = SIMD4<Float>.zero
        var skyColour = SIMD4<Float>.zero
        var groundColour = SIMD4<Float>.zero
        var clayColour = SIMD4<Float>.zero
        /// x: metres per shadow texel; y: shadowed brightness over
        /// textures; z: 1 when a shadow map is bound.
        var shadow = SIMD4<Float>.zero
        var flags: UInt32 = 0
    }

    /// Must match SunPathUniforms in `shaderSource`.
    private struct SunPathUniforms {
        var clipFromAnchor: simd_float4x4
        /// The viewport's width over height, so dots stay round.
        var aspect: Float
    }

    /// A frame's lighting after `prepare`: shared by every view (both eyes)
    /// of the frame.
    struct PreparedLighting {
        fileprivate var uniforms: LightUniforms
        let shadowMap: MTLTexture?
        let sunPath: MTLBuffer?
        let sunPathCount: Int
        let clearColour: MTLClearColor
    }

    /// Renders the frame's shadow map from the sun into `commands`, before
    /// any pass that draws the tiles, and packs `lighting` for `encode`.
    /// Once a frame: in stereo both eyes share the one map. No shadow map
    /// with the sun down, shadows off, or nothing loaded.
    func prepare(_ lighting: Lighting, commands: MTLCommandBuffer,
                 tiles: [(tile: CNTileMesh, placement: simd_float4x4)]) -> PreparedLighting {
        var uniforms = LightUniforms()
        uniforms.toSun = SIMD4(simd_normalize(lighting.toSun), lighting.sunStrength)
        uniforms.sunColour = SIMD4(lighting.sunColour, 1)
        uniforms.skyColour = SIMD4(lighting.skyColour, 1)
        uniforms.groundColour = SIMD4(lighting.groundColour, 1)
        uniforms.clayColour = SIMD4(lighting.clayColour, 1)
        uniforms.flags = (lighting.clay ? 1 : 0) | (lighting.shadowsOverTextures ? 2 : 0)
        var shadowMap: MTLTexture?
        if lighting.shadows, lighting.sunStrength > 0,
           let fit = shadowFit(lighting, tiles: tiles),
           let map = shadowTexture(size: lighting.shadowResolution),
           encodeShadowPass(commands: commands, into: map, clipFromAnchor: fit.clipFromAnchor, tiles: tiles) {
            shadowMap = map
            uniforms.shadowFromAnchor = fit.clipFromAnchor
            uniforms.shadow = SIMD4(Float(fit.texelSize), lighting.shadowedBrightness, 1, 0)
        }
        // Rebuilt every frame: under 200 dots, and a time-lapse moves them.
        // Too many for setVertexBytes's 4 KB.
        let sunPath: MTLBuffer? = lighting.sunPath.isEmpty ? nil : lighting.sunPath.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        return PreparedLighting(uniforms: uniforms, shadowMap: shadowMap, sunPath: sunPath,
                                sunPathCount: lighting.sunPath.count, clearColour: lighting.clearColour)
    }

    /// The sun's view over the shadow disc, deep enough for every drawn
    /// tile's bounds (corners through each tile's placement, so held tiles
    /// cast from where they're drawn).
    private func shadowFit(_ lighting: Lighting,
                           tiles: [(tile: CNTileMesh, placement: simd_float4x4)]) -> SunShadowFit? {
        var casters: [SIMD3<Double>] = []
        casters.reserveCapacity(tiles.count * 8)
        for (tile, placement) in tiles {
            guard let bounds = (tile.renderObject as? Tile)?.bounds else { continue }
            for corner in SunShadowFit.corners(minimum: SIMD3<Double>(bounds.minimum),
                                               maximum: SIMD3<Double>(bounds.maximum)) {
                let p = placement * SIMD4<Float>(SIMD3<Float>(corner), 1)
                casters.append(SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)))
            }
        }
        return SunShadowFit(sunDirection: SIMD3<Double>(lighting.toSun), casters: casters,
                            centre: lighting.shadowCentre, radius: lighting.shadowRadius,
                            resolution: lighting.shadowResolution)
    }

    private func shadowTexture(size: Int) -> MTLTexture? {
        shadowMapsLock.lock()
        defer { shadowMapsLock.unlock() }
        if let map = shadowMaps[size] { return map }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size,
                                                                  height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let map = device.makeTexture(descriptor: descriptor)
        map?.label = "Sun shadow map"
        shadowMaps[size] = map
        return map
    }

    /// Depth from the sun for every drawn tile the sun's view can see.
    private func encodeShadowPass(commands: MTLCommandBuffer, into map: MTLTexture, clipFromAnchor: simd_float4x4,
                                  tiles: [(tile: CNTileMesh, placement: simd_float4x4)]) -> Bool {
        let signposter = Signposts.frame
        let interval = signposter.beginInterval("MetalShadow", id: signposter.makeSignpostID())
        defer { signposter.endInterval("MetalShadow", interval) }
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = map
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .store
        guard let pipeline = pipeline(colour: .invalid, depth: map.pixelFormat, kind: .shadow),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return false }
        encoder.label = "Sun shadow"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(shadowDepthState)
        encoder.setCullMode(.none)
        for (tile, placement) in tiles {
            guard let gpu = tile.renderObject as? Tile else { continue }
            let clipFromLocal = clipFromAnchor * placement
            let frustum = cullsOffscreen ? MetalFrustum(clipFromLocal: clipFromLocal) : nil
            if frustum?.intersects(gpu.bounds) == false { continue }
            var uniforms = Uniforms(modelViewProjection: clipFromLocal, model: placement, anchorFromLocal: placement,
                                    baseColor: .one, flags: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
            for part in gpu.parts {
                if gpu.parts.count > 1, frustum?.intersects(part.bounds) == false { continue }
                encoder.setVertexBuffer(part.positions, offset: 0, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32,
                                              indexBuffer: part.indices, indexBufferOffset: 0)
            }
        }
        encoder.endEncoding()
        return true
    }

    /// The day's sun path as round dots, sized to the view, hidden behind
    /// anything nearer. `aspect` is the viewport's width over height.
    func encodeSunPath(_ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat,
                       viewProjection: simd_float4x4, root: simd_float4x4, lighting: PreparedLighting,
                       aspect: Float) {
        guard let dots = lighting.sunPath, lighting.sunPathCount > 0,
              let pipeline = pipeline(colour: colour, depth: depth, kind: .sunPath)
        else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        var uniforms = SunPathUniforms(clipFromAnchor: viewProjection * root, aspect: aspect)
        encoder.setVertexBuffer(dots, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SunPathUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: lighting.sunPathCount)
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
    float4x4 anchorFromLocal;
    float4 baseColor;
    uint flags;
};

constant uint kTextured = 1;
constant uint kLit = 2;

struct TileVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 normal;
    /// The sun study's: the anchor frame, metres.
    float3 anchorPosition;
    float3 anchorNormal;
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
    out.anchorPosition = (uniforms.anchorFromLocal * float4(positions[vid].xyz, 1)).xyz;
    out.anchorNormal = (uniforms.flags & kLit)
        ? (uniforms.anchorFromLocal * float4(normals[vid].xyz, 0)).xyz : float3(0, 1, 0);
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

// MARK: Sun study

// Must match MetalTileRenderer.LightUniforms.
struct LightUniforms {
    float4x4 shadowFromAnchor;
    float4 toSun;
    float4 eye;
    float4 sunColour;
    float4 skyColour;
    float4 groundColour;
    float4 clayColour;
    float4 shadow;
    uint flags;
};

constant uint kClay = 1;
constant uint kShadowsOverTextures = 2;

/// How much of the sun reaches `p`: 1 lit, 0 in shadow, from a 3 × 3
/// filtered comparison (PCF) of the sun's depth map. `p` is first moved a
/// texel or so off the surface, along its normal and toward the sun, so a
/// surface doesn't shadow itself (acne). Outside the map is lit.
static float sunVisibility(depth2d<float> shadowMap, constant LightUniforms &light, float3 p, float3 n) {
    float texel = light.shadow.x;
    float3 lifted = p + n * (1.5 * texel) + light.toSun.xyz * texel;
    float4 s = light.shadowFromAnchor * float4(lifted, 1);
    // Clip y is up; texture v is down.
    float2 uv = float2(s.x * 0.5 + 0.5, 0.5 - s.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0) || s.z < 0.0 || s.z > 1.0) {
        return 1.0;
    }
    // UNVERIFIED: Metal compares the reference (s.z) against the stored
    // depth, passing (1) where s.z <= stored, i.e. nothing nearer the sun.
    // If shadows come out inverted, the operand order is the other way:
    // use compare_func::greater_equal.
    constexpr sampler compare(coord::normalized, filter::linear, address::clamp_to_edge,
                              compare_func::less_equal);
    float2 step = 1.0 / float2(shadowMap.get_width(), shadowMap.get_height());
    float sum = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            // An explicit level: this runs in a branch, where implicit
            // derivatives aren't defined (and the map has one level).
            sum += shadowMap.sample_compare(compare, uv + float2(x, y) * step, s.z, level(0));
        }
    }
    return sum / 9.0;
}

/// Tiles lit by the sun study. Clay: the geometry alone, a matte model lit
/// by the sun (Lambert) and a sky-over-ground hemisphere, with shadows.
/// Otherwise the photographs as tileFragment draws them, darkened where the
/// sun doesn't reach if shadows over textures are on. Photogrammetry has no
/// normals, so a flat normal per pixel comes from the screen-space change
/// in position; turned to face the viewer, since that derivative's
/// handedness and the skins' winding are both unknowns.
fragment float4 studyFragment(TileVertexOut in [[stage_in]],
                              texture2d<float> texture [[texture(0)]],
                              sampler textureSampler [[sampler(0)]],
                              depth2d<float> shadowMap [[texture(1)]],
                              constant TileUniforms &uniforms [[buffer(0)]],
                              constant LightUniforms &light [[buffer(1)]]) {
    float3 p = in.anchorPosition;
    // Derivatives outside any branch, where they're always defined.
    float3 faceted = cross(dfdx(p), dfdy(p));
    float3 n = (uniforms.flags & kLit) ? in.anchorNormal : faceted;
    float lengthSquared = dot(n, n);
    n = lengthSquared > 0.0 ? n * rsqrt(lengthSquared) : float3(0, 1, 0);
    if (dot(n, light.eye.xyz - p) < 0.0) {
        n = -n;
    }
    float3 toSun = light.toSun.xyz;
    float strength = light.toSun.w;
    float facing = dot(n, toSun);
    float visible = (light.shadow.z > 0.0 && strength > 0.0 && facing > 0.0)
        ? sunVisibility(shadowMap, light, p, n) : 1.0;

    if (light.flags & kClay) {
        float3 ambient = mix(light.groundColour.rgb, light.skyColour.rgb, n.y * 0.5 + 0.5);
        float3 direct = light.sunColour.rgb * (max(facing, 0.0) * strength * visible);
        return float4(light.clayColour.rgb * (ambient + direct), 1);
    }

    float4 colour = uniforms.baseColor;
    if (uniforms.flags & kTextured) {
        colour *= texture.sample(textureSampler, in.uv);
    }
    if (uniforms.flags & kLit) {
        float lambert = max(facing, 0.0) * strength * visible;
        colour.rgb *= mix(light.skyColour.rgb + light.groundColour.rgb, float3(1), lambert);
    } else if (light.flags & kShadowsOverTextures) {
        // The photographs carry their own daylight, so only darken: faces
        // turned from the sun, shadows, and everything once the sun is down.
        float reach = smoothstep(-0.05, 0.1, facing) * visible;
        float shadowed = light.shadow.y * mix(0.4, 1.0, strength);
        colour.rgb *= mix(shadowed, 1.0, reach * strength);
    }
    return colour;
}

struct ShadowOut {
    float4 position [[position]];
};

/// The shadow pass: positions into the sun's view, depth only.
vertex ShadowOut shadowVertex(uint vid [[vertex_id]],
                              const device float4 *positions [[buffer(0)]],
                              constant TileUniforms &uniforms [[buffer(3)]]) {
    ShadowOut out;
    out.position = uniforms.modelViewProjection * float4(positions[vid].xyz, 1);
    return out;
}

// Must match MetalTileRenderer.SunPathDot and SunPathUniforms.
struct SunPathDot {
    float4 position;
    float4 colour;
};

struct SunPathUniforms {
    float4x4 clipFromAnchor;
    float aspect;
};

struct SunPathOut {
    float4 position [[position]];
    float2 corner;
    float4 colour;
};

/// One quad per dot (instanced, a 4-vertex strip), facing the view and a
/// fixed fraction of its height across, so it reads at any distance.
vertex SunPathOut sunPathVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                const device SunPathDot *dots [[buffer(0)]],
                                constant SunPathUniforms &uniforms [[buffer(1)]]) {
    SunPathDot point = dots[iid];
    float2 corner = float2(float(vid & 1) * 2 - 1, float(vid >> 1) * 2 - 1);
    float4 clip = uniforms.clipFromAnchor * float4(point.position.xyz, 1);
    clip.xy += corner * point.position.w * 2 * clip.w * float2(1 / uniforms.aspect, 1);
    SunPathOut out;
    out.position = clip;
    out.corner = corner;
    out.colour = point.colour;
    return out;
}

fragment float4 sunPathFragment(SunPathOut in [[stage_in]]) {
    if (length_squared(in.corner) > 1.0) {
        discard_fragment();
    }
    return in.colour;
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
