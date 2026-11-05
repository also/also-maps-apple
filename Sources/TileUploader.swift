import CoreGraphics
import Foundation
import OSLog
import Metal
import RealityKit

/// Turns tiles cesium-native has loaded into RealityKit entities without
/// stalling the main thread, and only then lets cesium-native count them as
/// loaded (CNTileStreamer.tileLoadHandler). Meshes are built off the main
/// thread; textures use RealityKit's async creation; a limiter caps how many
/// tiles are in flight so a burst doesn't create hundreds at once.
final class TileUploader: @unchecked Sendable {
    private let limiter = AsyncLimiter(limit: 4)
    /// Replaces the base colour of lit, untextured content when set, for
    /// sources whose tiles carry no colour (terrain). Set before streaming.
    var untexturedColor: SIMD4<Float>?

    func setConcurrency(_ limit: Int) {
        Task { await limiter.setLimit(max(1, limit)) }
    }

    var handler: CNTileLoadHandler {
        { [limiter, self] tile, completion in
            let tint = self.untexturedColor
            let signposter = Signposts.tiles
            let upload = signposter.beginInterval("TileUpload", id: signposter.makeSignpostID())
            Task.detached(priority: .userInitiated) {
                let wait = signposter.beginInterval("QueueWait", id: signposter.makeSignpostID())
                await limiter.acquire()
                signposter.endInterval("QueueWait", wait)
                await Self.build(tile, untexturedColor: tint)
                tile.discardCPUData()
                await limiter.release()
                signposter.endInterval("TileUpload", upload)
                completion()
            }
        }
    }

    // MARK: Building

    /// Meshes off the main thread, then textures and the entity on it.
    private static func build(_ tile: CNTileMesh, untexturedColor: SIMD4<Float>?) async {
        var parts: [Part] = []
        let signposter = Signposts.tiles
        let meshes = signposter.beginInterval("BuildMesh", id: signposter.makeSignpostID())
        for primitive in tile.primitives ?? [] {
            do {
                let mesh = try await MeshResource(from: [descriptor(for: primitive)])
                parts.append(Part(mesh: mesh, image: image(for: primitive), sampler: sampler(for: primitive),
                                  lit: primitive.normals != nil, baseColor: primitive.baseColor))
            } catch {
                print("[AlsoMaps] tile \(tile.identifier) mesh failed: \(error)")
            }
        }
        signposter.endInterval("BuildMesh", meshes)
        await assemble(parts, into: tile, untexturedColor: untexturedColor)
    }

    private struct Part {
        var mesh: MeshResource
        var image: CGImage?
        var sampler: MaterialParameters.Texture.Sampler
        /// Untextured content with normals: drawn lit, in its base colour.
        var lit: Bool
        var baseColor: SIMD4<Float>
    }

    @MainActor
    private static func assemble(_ parts: [Part], into tile: CNTileMesh, untexturedColor: SIMD4<Float>?) async {
        let signposter = Signposts.tiles
        let assembly = signposter.beginInterval("Assemble", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Assemble", assembly) }
        let entity = Entity()
        for part in parts {
            let material: any RealityKit.Material
            if part.lit {
                // Untextured content (e.g. OSM buildings) needs shading to read
                // as shapes; scene lighting comes from the environment.
                var lit = PhysicallyBasedMaterial()
                lit.baseColor = .init(tint: color(untexturedColor ?? part.baseColor))
                lit.roughness = .init(floatLiteral: 0.85)
                lit.metallic = .init(floatLiteral: 0)
                lit.faceCulling = .none
                material = lit
            } else {
                // Photogrammetry has its lighting baked in.
                var unlit = UnlitMaterial()
                unlit.faceCulling = .none
                if let image = part.image,
                   let texture = await Self.makeTexture(image) {
                    unlit.color = .init(tint: .white, texture: .init(texture, sampler: part.sampler))
                } else {
                    unlit.color = .init(tint: color(part.baseColor))
                }
                material = unlit
            }
            entity.addChild(ModelEntity(mesh: part.mesh, materials: [material]))
        }
        tile.renderObject = entity
    }

    private static func makeTexture(_ image: CGImage) async -> TextureResource? {
        let signposter = Signposts.tiles
        let state = signposter.beginInterval("Texture", id: signposter.makeSignpostID(),
                                             "\(image.width)x\(image.height)")
        defer { signposter.endInterval("Texture", state) }
        return try? await TextureResource(image: image, options: .init(semantic: .color))
    }

    /// glTF base colours are linear; Material.Color (UIColor or NSColor)
    /// components are sRGB.
    private static func color(_ linear: SIMD4<Float>) -> Material.Color {
        func encode(_ c: Float) -> CGFloat { CGFloat(pow(max(c, 0), 1 / 2.2)) }
        return Material.Color(red: encode(linear.x), green: encode(linear.y), blue: encode(linear.z), alpha: CGFloat(linear.w))
    }

    private static func descriptor(for primitive: CNPrimitive) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "tile")
        descriptor.positions = MeshBuffer(primitive.positions.withUnsafeBytes {
            Array($0.bindMemory(to: SIMD3<Float>.self))
        })
        if let normals = primitive.normals {
            descriptor.normals = MeshBuffer(normals.withUnsafeBytes {
                Array($0.bindMemory(to: SIMD3<Float>.self))
            })
        }
        if let texcoords = primitive.texcoords {
            descriptor.textureCoordinates = MeshBuffer(texcoords.withUnsafeBytes {
                Array($0.bindMemory(to: SIMD2<Float>.self))
            })
        }
        descriptor.primitives = .triangles(primitive.indices.withUnsafeBytes {
            Array($0.bindMemory(to: UInt32.self))
        })
        return descriptor
    }

    private static func sampler(for primitive: CNPrimitive) -> MaterialParameters.Texture.Sampler {
        .init(samplerDescriptor(for: primitive))
    }

    /// The glTF's sampler, for RealityKit and the Metal renderer. Wrap modes
    /// matter: Google's tiles ask for clamp-to-edge, and RealityKit's default
    /// repeats, which blends each tile's edge texels with the opposite edge
    /// into dark seams. Unspecified filters are trilinear.
    static func samplerDescriptor(for primitive: CNPrimitive) -> MTLSamplerDescriptor {
        func address(_ wrap: Int) -> MTLSamplerAddressMode {
            return switch wrap {
            case 33071: .clampToEdge
            case 33648: .mirrorRepeat
            default: .repeat
            }
        }
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = address(primitive.textureWrapS)
        descriptor.tAddressMode = address(primitive.textureWrapT)
        descriptor.magFilter = primitive.textureMagFilter == 9728 ? .nearest : .linear
        switch primitive.textureMinFilter {
        case 9728: (descriptor.minFilter, descriptor.mipFilter) = (.nearest, .notMipmapped)
        case 9729: (descriptor.minFilter, descriptor.mipFilter) = (.linear, .notMipmapped)
        case 9984: (descriptor.minFilter, descriptor.mipFilter) = (.nearest, .nearest)
        case 9985: (descriptor.minFilter, descriptor.mipFilter) = (.linear, .nearest)
        case 9986: (descriptor.minFilter, descriptor.mipFilter) = (.nearest, .linear)
        default: (descriptor.minFilter, descriptor.mipFilter) = (.linear, .linear)
        }
        return descriptor
    }

    private static func image(for primitive: CNPrimitive) -> CGImage? {
        guard let rgba = primitive.rgba,
              primitive.textureWidth > 0, primitive.textureHeight > 0,
              let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: primitive.textureWidth,
                       height: primitive.textureHeight,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: primitive.textureWidth * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

/// A counting semaphore for async code.
actor AsyncLimiter {
    private var limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if !waiters.isEmpty, inFlight <= limit {
            waiters.removeFirst().resume()  // hand the slot straight over
        } else {
            inFlight -= 1
        }
    }

    func setLimit(_ newLimit: Int) {
        limit = newLimit
        while inFlight < limit, !waiters.isEmpty {
            inFlight += 1
            waiters.removeFirst().resume()
        }
    }
}
