import Foundation
import RealityKit

/// Live aircraft over the map (Settings › General › Live air traffic, or
/// ALSOMAPS_AIR_TRAFFIC=1): a small plane for each, turned to its track and
/// climb, with a trail of its last few minutes that fades with age. See
/// notes/live-air-traffic.md.
///
/// The host calls `update` every frame with its georeference and the sizes
/// it wants, chosen like the track tube's: the same size in a room at any
/// map scale, or in proportion to the camera's altitude on a screen. While
/// it's being called and the feature is on, the feed polls for the area
/// being streamed.
///
/// Markers sit directly in the map frame, each placed from double precision
/// every frame. Trails are one mesh per age band for every aircraft at once,
/// relative to a fixed ECEF origin near them (like TrackOverlay), rebuilt a
/// few times a second.
@MainActor
final class AirTrafficOverlay {
    let root = Entity()
    let feed: AirTrafficFeed

    /// What the host wants drawn, in world metres.
    struct Size {
        /// Nose to tail.
        var markerLength: Double
        var trailRadius: Double

        /// In a room: a 4 cm plane with a 2 mm trail, whatever the map's
        /// scale (`scale`, room metres per world metre).
        static func room(scale: Double) -> Size {
            Size(markerLength: 0.04 / scale, trailRadius: 0.002 / scale)
        }

        /// On a screen, in proportion to the camera's height above the
        /// ground: a dozen pixels where you're looking, and the trail as thin
        /// as the track tube.
        static func screen(altitude: Double) -> Size {
            Size(markerLength: 0.04 * altitude, trailRadius: 0.6 * TrackOverlay.screenRadiusPerAltitude * altitude)
        }
    }

    /// Fading steps along a trail, newest (most opaque) first.
    static let bandOpacities: [Float] = [0.85, 0.55, 0.3, 0.12]
    /// How often trails are rebuilt, seconds.
    static let trailRedrawInterval = 0.25
    /// The trail origin moves once the area is this far from it (metres),
    /// keeping Float offsets within a few millimetres.
    static let trailOriginReach = 150_000.0

    private var tracker = AirTrafficTracker()
    private let markersRoot = Entity()
    private var markers: [String: ModelEntity] = [:]
    private let markerMesh: MeshResource?
    private let markerMaterial: Material
    private let trailsRoot = Entity()
    private let bandModels: [ModelEntity]
    private var extruders: [TubeExtruder]
    /// ECEF metres; trail points are relative to it.
    private var trailOrigin: SIMD3<Double>?
    private var lastTrailDraw = -Double.infinity
    private var lastSettingCheck = -Double.infinity
    /// The host's ground estimate, for aircraft on the ground with only a
    /// barometric "ground".
    private var groundHeight = 0.0

    init(feed: AirTrafficFeed = AirTrafficFeed()) {
        self.feed = feed
        markerMesh = Self.makeMarkerMesh()
        markerMaterial = Self.material(opacity: 1)
        bandModels = Self.bandOpacities.map { _ in ModelEntity() }
        extruders = Self.bandOpacities.map { _ in TubeExtruder(sides: 6) }
        root.addChild(markersRoot)
        root.addChild(trailsRoot)
        for model in bandModels { trailsRoot.addChild(model) }
        root.isEnabled = false
        feed.onSnapshot = { [weak self] snapshot, time in
            guard let self else { return }
            self.tracker.merge(snapshot, receivedAt: time, groundHeight: self.groundHeight)
        }
    }

    /// Places everything for this frame. `streaming` is what the host
    /// streams: the area polled, and its anchor height the ground estimate.
    func update(georeference: Georeference, size: Size, streaming: StreamingInputs) {
        let now = feed.clock()
        // The setting is read about once a second, so Settings applies live.
        if now - lastSettingCheck >= 1 {
            lastSettingCheck = now
            setEnabled(ViewPreferences.showsAirTraffic)
        }
        guard root.isEnabled, georeference.scale > 0, size.markerLength > 0 else { return }

        groundHeight = streaming.anchor.height
        let area = AirTrafficArea(streaming: streaming)
        feed.frame(area: area, now: now)
        let states = tracker.advance(to: now, groundHeight: groundHeight)
        placeMarkers(states, georeference: georeference, size: size)

        let centre = Geodesy.ecef(area.centre, height: groundHeight)
        var redraw = now - lastTrailDraw >= Self.trailRedrawInterval
        if trailOrigin.map({ simd_distance($0, centre) > Self.trailOriginReach }) ?? true {
            trailOrigin = centre
            redraw = true
        }
        guard let trailOrigin else { return }
        trailsRoot.transform = Transform(Similarity(scale: georeference.scale,
                                                    rotation: georeference.rotation,
                                                    translation: georeference.map(trailOrigin)))
        if redraw {
            lastTrailDraw = now
            drawTrails(states, origin: trailOrigin, radius: size.trailRadius)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard enabled != root.isEnabled else { return }
        root.isEnabled = enabled
        if enabled {
            feed.start()
        } else {
            feed.stop()
            tracker.removeAll()
            for marker in markers.values { marker.removeFromParent() }
            markers.removeAll()
            drawTrails([], origin: trailOrigin ?? .zero, radius: 1)
        }
        #if DEBUG
        print("[AlsoMaps] air traffic \(enabled ? "on" : "off")")
        #endif
    }

    // MARK: Markers

    private func placeMarkers(_ states: [AirTrafficTracker.State], georeference: Georeference, size: Size) {
        guard let markerMesh else { return }
        let scale = Float(size.markerLength * georeference.scale)
        var shown = Set<String>()
        for state in states {
            shown.insert(state.id)
            let marker: ModelEntity
            if let existing = markers[state.id] {
                marker = existing
            } else {
                marker = ModelEntity(mesh: markerMesh, materials: [markerMaterial])
                marker.name = "aircraft-\(state.id)"
                markersRoot.addChild(marker)
                markers[state.id] = marker
            }
            let rotation = georeference.rotation
                * AircraftPose.rotation(heading: state.heading, pitch: state.pitch, at: state.coordinate)
            marker.transform = Transform(scale: SIMD3(repeating: scale),
                                         rotation: simd_quatf(vector: SIMD4<Float>(rotation.vector)),
                                         translation: SIMD3<Float>(georeference.map(state.position)))
        }
        for (id, marker) in markers where !shown.contains(id) {
            marker.removeFromParent()
            markers[id] = nil
        }
    }

    // MARK: Trails

    private func drawTrails(_ states: [AirTrafficTracker.State], origin: SIMD3<Double>, radius: Double) {
        var polylines = [[[SIMD3<Float>]]](repeating: [], count: Self.bandOpacities.count)
        for state in states {
            let bands = TrailBands.split(state.trail, bands: polylines.count, duration: AircraftMotion.trailDuration)
            for (band, line) in bands.enumerated() where line.count > 1 {
                polylines[band].append(line.map { SIMD3<Float>($0 - origin) })
            }
        }
        for band in polylines.indices {
            do {
                if let mesh = try extruders[band].update(polylines: polylines[band], radius: Float(radius)) {
                    bandModels[band].model = ModelComponent(mesh: try MeshResource(from: mesh),
                                                            materials: [Self.material(opacity: Self.bandOpacities[band])])
                }
            } catch {
                print("[AlsoMaps] couldn't build the air traffic trails: \(error)")
            }
        }
    }

    // MARK: Appearance

    private static func material(opacity: Float) -> Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .systemCyan)
        material.roughness = 0.5
        material.emissiveColor = .init(color: .systemCyan)
        material.emissiveIntensity = 0.4
        if opacity < 1 {
            // UNVERIFIED: PhysicallyBasedMaterial.Opacity(scale:) as the
            // transparent blending's opacity.
            material.blending = .transparent(opacity: .init(scale: opacity))
        }
        return material
    }

    /// A paper dart, unit length, nose at −z: a diamond fuselage, swept
    /// wings, a tailplane and a fin, each flat face its own vertices so it's
    /// lit flat. Wings and tail are thin, so they're two-sided.
    private static func makeMarkerMesh() -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, twoSided: Bool = false) {
            let normal = simd_normalize(simd_cross(b - a, c - a))
            positions += [a, b, c]
            normals += [normal, normal, normal]
            if twoSided {
                positions += [a, c, b]
                normals += [-normal, -normal, -normal]
            }
        }
        // Fuselage: nose and tail points joined through a diamond.
        let nose: SIMD3<Float> = [0, 0, -0.5], tail: SIMD3<Float> = [0, 0, 0.5]
        let ring: [SIMD3<Float>] = [[0.06, 0, -0.15], [0, 0.06, -0.15], [-0.06, 0, -0.15], [0, -0.06, -0.15]]
        for i in 0..<4 {
            let a = ring[i], b = ring[(i + 1) % 4]
            triangle(nose, b, a)
            triangle(tail, a, b)
        }
        // Wings, tailplane and fin.
        for side: Float in [-1, 1] {
            triangle([0, 0, -0.2], [side * 0.5, 0, 0.15], [0, 0, 0.1], twoSided: true)
            triangle([0, 0, 0.32], [side * 0.2, 0, 0.5], [0, 0, 0.5], twoSided: true)
        }
        triangle([0, 0, 0.25], [0, 0.22, 0.5], [0, 0, 0.5], twoSided: true)

        var descriptor = MeshDescriptor(name: "aircraft")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles((0..<UInt32(positions.count)).map { $0 })
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            print("[AlsoMaps] couldn't build the aircraft marker: \(error)")
            return nil
        }
    }
}
