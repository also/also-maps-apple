import Foundation
import RealityKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An imported route drawn as a tube on the map, coloured by value, and
/// during a replay a ball at the moving point. Like TrackOverlay: the host
/// picks the tube's radius in the world each frame, the mesh is rebuilt
/// when that has changed by a step and simplified to a fraction of it, and
/// the root sits at the route's origin, placed from the georeference
/// composed in double.
///
/// Each colour is its own TubeExtruder mesh with its own material
/// (RouteColourScale.colours), rather than one mesh with a colour per
/// vertex: RealityKit's built-in materials don't read a vertex colour, and
/// there are only ten colours.
@MainActor
final class RouteOverlay {
    let root = Entity()
    private var models: [ModelEntity] = []
    private var extruders: [TubeExtruder] = []
    private let materials: [Material]
    private let marker: ModelEntity

    /// The tube's radius in a room, metres: a little thicker than a
    /// camera track's, so a route stands out from one.
    static let roomRadius = 0.006
    /// The tube's radius on a screen, as a fraction of the camera's height
    /// above the ground.
    static let screenRadiusPerAltitude = 0.002
    /// The moving point's radius, in tube radii.
    static let markerRadius = 3.0
    /// Rebuilds when the tube's world radius has changed by this factor.
    static let scaleStep = 1.25
    /// The simplification tolerance as a fraction of the world radius.
    static let toleranceFraction = 0.25

    /// What's drawn; nil draws nothing.
    var geometry: RouteGeometry? {
        didSet { drawnStep = nil }
    }
    /// The moving point during a replay, ECEF; nil hides the ball.
    var markerPosition: SIMD3<Double>?
    /// The radius step the meshes were built for.
    private var drawnStep: Int?

    init() {
        materials = RouteColourScale.colours.map { Self.material($0) }
        var white = UnlitMaterial()
        white.color = .init(tint: .white)
        marker = ModelEntity(mesh: .generateSphere(radius: 1), materials: [white])
        for _ in RouteColourScale.colours {
            let model = ModelEntity()
            model.isEnabled = false
            root.addChild(model)
            models.append(model)
            extruders.append(TubeExtruder(sides: 8))
        }
        marker.isEnabled = false
        root.addChild(marker)
        root.isEnabled = false
    }

    var isEnabled: Bool {
        get { root.isEnabled }
        set { root.isEnabled = newValue }
    }

    /// Places the route for this frame's georeference (ECEF → map frame),
    /// moves the ball, and rebuilds the tubes if their world radius
    /// (metres) has stepped or the geometry has changed.
    func update(georeference: Georeference, worldRadius: Double) {
        guard root.isEnabled, let geometry, georeference.scale > 0, worldRadius > 0 else { return }
        root.transform = Transform(Similarity(scale: georeference.scale,
                                              rotation: georeference.rotation,
                                              translation: georeference.map(geometry.origin)))

        let step = Int((log(worldRadius) / log(Self.scaleStep)).rounded())
        let radius = pow(Self.scaleStep, Double(step))
        // A draped route sits on the surface rather than half in it.
        let lift = geometry.liftsByRadius ? geometry.up * radius : .zero

        if let markerPosition {
            marker.isEnabled = true
            marker.position = SIMD3<Float>(markerPosition - geometry.origin + lift)
            marker.scale = SIMD3(repeating: Float(Self.markerRadius * radius))
        } else {
            marker.isEnabled = false
        }

        guard drawnStep != step else { return }
        let tolerance = Self.toleranceFraction * radius
        let offset = SIMD3<Float>(lift)
        var polylines = [[[SIMD3<Float>]]](repeating: [], count: models.count)
        for run in geometry.runs where run.bin < models.count {
            polylines[run.bin].append(run.points(tolerance: tolerance).map { $0 + offset })
        }
        for i in models.indices {
            models[i].isEnabled = !polylines[i].isEmpty
            guard !polylines[i].isEmpty else { continue }
            do {
                if let mesh = try extruders[i].update(polylines: polylines[i], radius: Float(radius)) {
                    models[i].model = ModelComponent(mesh: try MeshResource(from: mesh), materials: [materials[i]])
                }
            } catch {
                print("[AlsoMaps] couldn't build the route's mesh: \(error)")
            }
        }
        drawnStep = step
        #if DEBUG
        let kept = polylines.joined().reduce(0) { $0 + $1.count }
        print("[AlsoMaps] route drawn: \(kept) points in \(geometry.runs.count) runs, radius \(String(format: "%.3g", radius)) m")
        #endif
    }

    private static func material(_ colour: SIMD3<Float>) -> Material {
        #if os(macOS)
        let tint = NSColor(srgbRed: CGFloat(colour.x), green: CGFloat(colour.y), blue: CGFloat(colour.z), alpha: 1)
        #else
        let tint = UIColor(red: CGFloat(colour.x), green: CGFloat(colour.y), blue: CGFloat(colour.z), alpha: 1)
        #endif
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: tint)
        material.roughness = 0.5
        material.emissiveColor = .init(color: tint)
        material.emissiveIntensity = 0.3
        return material
    }
}
