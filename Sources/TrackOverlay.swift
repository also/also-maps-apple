import Foundation
import RealityKit
import UIKit

/// A camera track drawn as a tube on the map: one tube per segment, no
/// tube across a jump. The tube keeps the same thickness in the room at any
/// map scale, so its radius in the world changes with the scale; the mesh is
/// rebuilt whenever that radius has changed by a step (`scaleStep`), and
/// simplified to a fraction of it, which is never visible. The track grows
/// as samples are appended, redrawn at most every `growthInterval`.
///
/// The entity sits in the map frame at the track's origin, placed each frame
/// from the georeference composed in double, so the Float vertices stay
/// small and the tube moves with the tiles.
@MainActor
final class TrackOverlay {
    let root = Entity()
    private let model = ModelEntity()
    private var extruder = TubeExtruder(sides: 8)

    /// The tube's radius in the room, metres.
    static let roomRadius = 0.005
    /// Rebuilds when the tube's world radius has changed by this factor, so
    /// its thickness in the room stays within about ±12% between rebuilds.
    static let scaleStep = 1.25
    /// The simplification tolerance as a fraction of the world radius.
    static let toleranceFraction = 0.25
    static let growthInterval: TimeInterval = 0.25

    /// The track drawn; nil draws nothing.
    var path: TrackPath? {
        didSet { drawn = nil }
    }
    /// What the mesh shows: the path's version and the radius step.
    private var drawn: (version: Int, step: Int)?
    private var lastDraw = Date.distantPast

    init() {
        root.addChild(model)
        root.isEnabled = false
    }

    var isEnabled: Bool {
        get { root.isEnabled }
        set { root.isEnabled = newValue }
    }

    /// Adds a sample to the track, starting one if there's none.
    func append(_ sample: CameraTrack.Sample) {
        if path == nil {
            path = TrackPath(samples: [sample])
        } else {
            path?.append(sample)
        }
    }

    /// Places the tube for this frame's georeference (ECEF → map frame) and
    /// rebuilds it if the scale has stepped or the track has grown.
    func update(georeference: Georeference, now: Date = Date()) {
        guard root.isEnabled, let path, georeference.scale > 0 else { return }
        root.transform = Transform(Similarity(scale: georeference.scale,
                                              rotation: georeference.rotation,
                                              translation: georeference.map(path.origin)))

        let worldRadius = Self.roomRadius / georeference.scale
        let step = Int((log(worldRadius) / log(Self.scaleStep)).rounded())
        if let drawn, drawn.step == step,
           drawn.version == path.version || now.timeIntervalSince(lastDraw) < Self.growthInterval {
            return
        }
        let radius = pow(Self.scaleStep, Double(step))
        let tolerance = Self.toleranceFraction * radius
        let polylines = path.segments.indices.map { path.points(inSegment: $0, tolerance: tolerance) }
        do {
            if let mesh = try extruder.update(polylines: polylines, radius: Float(radius)) {
                model.model = ModelComponent(mesh: try MeshResource(from: mesh), materials: [Self.material])
            }
        } catch {
            print("[AlsoMaps] couldn't build the track's mesh: \(error)")
        }
        drawn = (path.version, step)
        lastDraw = now
        #if DEBUG
        let kept = polylines.reduce(0) { $0 + $1.count }
        print("[AlsoMaps] track drawn: \(kept) of \(path.pointCount) points in \(polylines.count) segments, radius \(String(format: "%.3g", radius)) m")
        #endif
    }

    private static let material: Material = {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .systemOrange)
        material.roughness = 0.5
        material.emissiveColor = .init(color: .systemOrange)
        material.emissiveIntensity = 0.3
        return material
    }()
}
