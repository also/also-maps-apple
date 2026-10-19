import Foundation
import Observation
import RealityKit
import SwiftUI
import UIKit

/// Owns the cesium-native streamer and mirrors its selected tiles as
/// RealityKit entities under `root`.
@MainActor
@Observable
final class MapVolumeModel {
    /// Volume extents in metres (width, height, depth).
    static let volumeSize = SIMD3<Double>(1.0, 0.6, 1.0)
    /// Where the ground plane sits inside the volume (origin is the centre).
    private static let groundY: Float = -0.25
    /// How far a typical viewer stands from the volume; drives LOD.
    private static let viewerDistanceInScene = 1.2
    /// Budget per frame for turning CPU meshes into RealityKit resources.
    private static let uploadBudget: TimeInterval = 0.006

    struct Location {
        var latitude: Double
        var longitude: Double
        var radius: Double
    }

    static let defaultLocation = Location(latitude: 37.7955, longitude: -122.3937, radius: 600)

    let root = Entity()
    /// Invisible box that receives drag / magnify gestures.
    let gestureTarget = Entity()

    private(set) var credits: [String] = []
    private(set) var loadProgress: Float = 0
    private(set) var statusMessage: String?

    private var streamer: CNTileStreamer?
    private let tilesRoot = Entity()
    private var tileEntities: [UInt64: Entity] = [:]
    private var updateSubscription: EventSubscription?
    private var debugLogElapsed: Float = 0

    // Gesture state.
    private var dragStartFocus: (east: Double, north: Double)?
    private var magnifyStartRadius: Double?

    private var focusEast = 0.0
    private var focusNorth = 0.0
    private var focusHeight = 0.0
    /// Where focusHeight is easing toward; set by the latest ground sample.
    private var targetFocusHeight: Double?
    /// Bumped per sample request so a slow, older result can't win.
    private var groundSampleGeneration = 0
    private var radius = defaultLocation.radius

    init() {
        root.addChild(tilesRoot)

        let size = SIMD3<Float>(Self.volumeSize)
        gestureTarget.components.set(InputTargetComponent())
        gestureTarget.components.set(CollisionComponent(shapes: [.generateBox(size: size)]))
        root.addChild(gestureTarget)
    }

    func start(subscribingIn content: RealityViewContent) {
        guard streamer == nil else { return }

        // Debug overrides: MAPVOLUME_LAT/_LON/_RADIUS pick the starting view, and
        // MAPVOLUME_TILESET_URL streams any 3D Tiles tileset instead of
        // Google's, no key needed.
        let env = ProcessInfo.processInfo.environment
        var location = Self.defaultLocation
        location.latitude = env["MAPVOLUME_LAT"].flatMap(Double.init) ?? location.latitude
        location.longitude = env["MAPVOLUME_LON"].flatMap(Double.init) ?? location.longitude
        location.radius = env["MAPVOLUME_RADIUS"].flatMap(Double.init) ?? location.radius
        let url: String
        if let override = env["MAPVOLUME_TILESET_URL"], !override.isEmpty {
            url = override
        } else if let key = Self.apiKey() {
            url = "https://tile.googleapis.com/v1/3dtiles/root.json?key=\(key)"
        } else {
            statusMessage = "Set GOOGLE_MAPS_API_KEY in Config/Secrets.xcconfig (or the scheme environment)."
            return
        }
        radius = location.radius

        let streamer = CNTileStreamer(tilesetURL: url,
                                      originLatitude: location.latitude,
                                      longitude: location.longitude,
                                      height: 0)
        self.streamer = streamer
        applyFocus()
        sampleGround()

        updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.tick(deltaTime: Float(event.deltaTime))
            }
        }
    }

    // MARK: Gestures

    /// `translation` is the drag in scene metres since the gesture began.
    func drag(translation: SIMD3<Float>) {
        if dragStartFocus == nil { dragStartFocus = (focusEast, focusNorth) }
        guard let start = dragStartFocus else { return }
        let metresPerScene = 1 / sceneScale
        // Content follows the hand: dragging right reveals what's west.
        focusEast = start.east - Double(translation.x) * metresPerScene
        // RealityKit +z is south, so dragging toward you reveals the north.
        focusNorth = start.north + Double(translation.z) * metresPerScene
        applyFocus()
    }

    func endDrag() {
        dragStartFocus = nil
        sampleGround()
    }

    func magnify(by magnification: Double) {
        if magnifyStartRadius == nil { magnifyStartRadius = radius }
        guard let start = magnifyStartRadius, magnification > 0 else { return }
        radius = min(max(start / magnification, 50), 20_000)
        applyFocus()
    }

    func endMagnify() {
        magnifyStartRadius = nil
        // The sampled region grows and shrinks with the radius.
        sampleGround()
    }

    // MARK: Frame loop

    private func tick(deltaTime: Float) {
        guard let streamer else { return }
        easeFocusHeight(deltaTime: Double(deltaTime))
        let frame = streamer.update(withDeltaTime: deltaTime)

        for id in frame.freedTileIDs {
            tileEntities.removeValue(forKey: id.uint64Value)?.removeFromParent()
        }

        let deadline = Date().addingTimeInterval(Self.uploadBudget)
        var visible = Set<UInt64>()
        for tile in frame.tilesToRender {
            visible.insert(tile.identifier)
            if tileEntities[tile.identifier] == nil, Date() < deadline {
                let entity = Self.makeEntity(for: tile)
                tileEntities[tile.identifier] = entity
                tilesRoot.addChild(entity)
            }
        }
        for (id, entity) in tileEntities {
            entity.isEnabled = visible.contains(id)
        }

        if credits != frame.credits { credits = frame.credits }
        loadProgress = frame.loadProgress

        #if DEBUG
        debugLogElapsed += deltaTime
        if debugLogElapsed > 1 {
            debugLogElapsed = 0
            print("[MapVolume] render \(frame.tilesToRender.count) tiles, \(tileEntities.count) entities, progress \(Int(frame.loadProgress))%, focus height \(Int(focusHeight)) m")
        }
        #endif
    }

    // MARK: Helpers

    /// Scene metres per world metre.
    private var sceneScale: Double { (Self.volumeSize.x / 2) / radius }

    private func applyFocus() {
        guard let streamer else { return }
        streamer.focusEast = focusEast
        streamer.focusNorth = focusNorth
        streamer.focusHeight = focusHeight
        streamer.focusRadius = radius
        streamer.viewerDistance = Self.viewerDistanceInScene / sceneScale

        // Tiles are baked in the origin's local frame (x east, y up, z south);
        // place the focus point on the volume's ground plane.
        let s = Float(sceneScale)
        tilesRoot.scale = SIMD3(repeating: s)
        tilesRoot.position = SIMD3(Float(-focusEast) * s,
                                   Self.groundY - Float(focusHeight) * s,
                                   Float(focusNorth) * s)
    }

    private func sampleGround() {
        groundSampleGeneration += 1
        let generation = groundSampleGeneration
        streamer?.sampleGroundHeightInFocusRegion { [weak self] height in
            MainActor.assumeIsolated {
                guard let self, height.isFinite,
                      generation == self.groundSampleGeneration else { return }
                #if DEBUG
                print("[MapVolume] ground sample \(Int(height)) m (was \(Int(self.focusHeight)) m)")
                #endif
                self.targetFocusHeight = height
            }
        }
    }

    /// Glides the ground plane to the latest sample instead of snapping, so a
    /// re-sample after a pan reads as the terrain settling rather than a jump.
    private func easeFocusHeight(deltaTime: Double) {
        guard let target = targetFocusHeight else { return }
        let remaining = target - focusHeight
        if abs(remaining) * sceneScale < 0.0005 {
            focusHeight = target
            targetFocusHeight = nil
        } else {
            // Exponential approach: about 95% of the way in half a second.
            focusHeight += remaining * min(1, deltaTime * 6)
        }
        applyFocus()
    }

    private static func apiKey() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["GOOGLE_MAPS_API_KEY"],
            Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String,
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("$(") && $0 != "YOUR_KEY_HERE" }
    }

    private static func makeEntity(for tile: CNTileMesh) -> Entity {
        let entity = Entity()
        for primitive in tile.primitives ?? [] {
            do {
                entity.addChild(try makeModel(for: primitive))
            } catch {
                print("[MapVolume] tile \(tile.identifier) primitive failed: \(error)")
            }
        }
        tile.discardCPUData()
        return entity
    }

    private static func makeModel(for primitive: CNPrimitive) throws -> ModelEntity {
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
        let mesh = try MeshResource.generate(from: [descriptor])

        var material = UnlitMaterial()
        material.faceCulling = .none
        if let rgba = primitive.rgba, let image = makeImage(rgba: rgba,
                                                            width: primitive.textureWidth,
                                                            height: primitive.textureHeight) {
            let texture = try TextureResource.generate(from: image,
                                                       options: .init(semantic: .color))
            material.color = .init(tint: .white, texture: .init(texture))
        } else {
            material.color = .init(tint: .gray)
        }
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private static func makeImage(rgba: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
