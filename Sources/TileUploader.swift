import CoreGraphics
import Foundation
import RealityKit

/// Turns tiles cesium-native has loaded into RealityKit entities without
/// stalling the main thread, and only then lets cesium-native count them as
/// loaded (CNTileStreamer.tileLoadHandler). Meshes are built off the main
/// thread; textures use RealityKit's async creation; a limiter caps how many
/// tiles are in flight so a burst doesn't create hundreds at once.
final class TileUploader: @unchecked Sendable {
    private let limiter = AsyncLimiter(limit: 4)

    func setConcurrency(_ limit: Int) {
        Task { await limiter.setLimit(max(1, limit)) }
    }

    var handler: CNTileLoadHandler {
        { [limiter] tile, completion in
            Task.detached(priority: .userInitiated) {
                await limiter.acquire()
                await Self.build(tile)
                tile.discardCPUData()
                await limiter.release()
                completion()
            }
        }
    }

    // MARK: Building

    /// Meshes off the main thread, then textures and the entity on it.
    private static func build(_ tile: CNTileMesh) async {
        var parts: [(mesh: MeshResource, image: CGImage?)] = []
        for primitive in tile.primitives ?? [] {
            do {
                let mesh = try await MeshResource(from: [descriptor(for: primitive)])
                parts.append((mesh, image(for: primitive)))
            } catch {
                print("[MapVolume] tile \(tile.identifier) mesh failed: \(error)")
            }
        }
        await assemble(parts, into: tile)
    }

    @MainActor
    private static func assemble(_ parts: [(mesh: MeshResource, image: CGImage?)], into tile: CNTileMesh) async {
        let entity = Entity()
        for part in parts {
            var material = UnlitMaterial()
            material.faceCulling = .none
            if let image = part.image,
               let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) {
                material.color = .init(tint: .white, texture: .init(texture))
            } else {
                material.color = .init(tint: .gray)
            }
            entity.addChild(ModelEntity(mesh: part.mesh, materials: [material]))
        }
        tile.renderObject = entity
    }

    private static func descriptor(for primitive: CNPrimitive) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "tile")
        descriptor.positions = MeshBuffer(primitive.positions.withUnsafeBytes {
            Array($0.bindMemory(to: SIMD3<Float>.self))
        })
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
