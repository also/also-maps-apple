import simd
import SwiftUI

/// The world side view of a CameraDiagram: the camera's vertical plane, with
/// the ground estimates, where the eye is, what it looks at and the LOD
/// camera.
struct CameraDiagramWorldView: View {
    let diagram: CameraDiagram

    var body: some View {
        Canvas { context, size in
            let fit = DiagramFit(bounds: diagram.worldBounds, size: size)
            let d = diagram

            // The Earth below the ellipsoid.
            if let ellipsoid = d.surfaces.first(where: { $0.kind == .ellipsoid }) {
                context.fill(fit.ground(ellipsoid.world, centre: d.earthCentre, closes: ellipsoid.closesWorld),
                             with: .color(.gray.opacity(0.12)))
            }
            context.stroke(fit.line(d.streamedArea), with: .color(DiagramStyle.streamed.opacity(0.3)), lineWidth: 13)
            if d.shownRegion.count >= 2 {
                context.stroke(fit.line(d.shownRegion), with: .color(DiagramStyle.shown.opacity(0.4)), lineWidth: 7)
            }
            context.fill(fit.cone(d.viewer), with: .color(DiagramStyle.lod.opacity(0.1)))
            context.stroke(fit.cone(d.viewer), with: .color(DiagramStyle.lod.opacity(0.5)), lineWidth: 1)
            for surface in d.surfaces {
                DiagramStyle.stroke(surface.kind, fit.line(surface.world), in: &context)
            }

            DiagramStyle.tick(at: fit.point(d.horizonPoint), in: &context)
            DiagramStyle.label("horizon", at: fit.point(d.horizonPoint), in: &context, below: true)
            if let g = d.georeferencePoint {
                if let placed = d.placedPoint, fit.distance(g, placed) > 10 {
                    context.stroke(fit.line([g, placed]), with: .color(DiagramStyle.placement),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    DiagramStyle.diamond(at: fit.point(placed), in: &context)
                    DiagramStyle.label("placed", at: fit.point(placed), in: &context)
                }
                DiagramStyle.cross(at: fit.point(g), in: &context)
                DiagramStyle.label("view centre", at: fit.point(g), in: &context)
            }

            DiagramStyle.marker(camera: d.camera, viewer: d.viewer, viewerName: DiagramStyle.viewerName(d),
                                underground: d.viewerAltitude < 0, fit: fit, in: &context)
        }
        .clipped()
    }
}

/// The room side view: the host's geometry and the world as it places it,
/// seen from the side with the viewer on the left.
struct CameraDiagramRoomView: View {
    let diagram: CameraDiagram

    var body: some View {
        Canvas { context, size in
            guard let room = diagram.room else { return }
            let fit = DiagramFit(bounds: room.bounds, size: size)

            if let terrain = diagram.surfaces.first(where: { $0.kind == .terrain }), !terrain.room.isEmpty {
                context.fill(fit.ground(terrain.room, centre: room.earthCentre, closes: false),
                             with: .color(.brown.opacity(0.12)))
            }
            if let container = room.container {
                context.stroke(Path(fit.rect(container)), with: .color(.secondary), lineWidth: 1)
            }
            let base = room.basePlaneHeight
            context.stroke(fit.line([SIMD2(room.bounds.min.x, base), SIMD2(room.bounds.max.x, base)]),
                           with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            context.stroke(fit.line(room.streamedArea), with: .color(DiagramStyle.streamed.opacity(0.3)), lineWidth: 13)
            let level = room.levelPlacement
            context.stroke(fit.line([level - SIMD2(room.contentHalfWidth, 0), level + SIMD2(room.contentHalfWidth, 0)]),
                           with: .color(DiagramStyle.shown.opacity(0.4)), lineWidth: 7)

            context.fill(fit.cone(room.lod), with: .color(DiagramStyle.lod.opacity(0.1)))
            context.stroke(fit.cone(room.lod), with: .color(DiagramStyle.lod.opacity(0.5)), lineWidth: 1)
            for surface in diagram.surfaces where !surface.room.isEmpty {
                DiagramStyle.stroke(surface.kind, fit.line(surface.room), in: &context)
            }

            for (point, name) in [(room.levelPlacement, "C₀"), (room.downPlacement, "C₁")] {
                DiagramStyle.tick(at: fit.point(point), in: &context)
                DiagramStyle.label(name, at: fit.point(point), in: &context)
            }
            DiagramStyle.cross(at: fit.point(room.placement), in: &context)
            DiagramStyle.label("view centre", at: fit.point(room.placement), in: &context, below: true, left: true)

            let camera = CameraDiagram.Viewpoint(position: room.camera, direction: room.lod.direction)
            let eye = CameraDiagram.Viewpoint(position: room.eye, direction: room.lod.direction)
            DiagramStyle.marker(camera: camera, viewer: eye, viewerName: DiagramStyle.viewerName(diagram),
                                underground: diagram.viewerAltitude < 0, fit: fit, in: &context)
        }
        .clipped()
    }
}

/// Swatches for what the side views draw.
struct CameraDiagramLegend: View {
    let diagram: CameraDiagram

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading,
                  spacing: 4) {
            items(diagram.surfaces.map(\.kind))
        }
        .font(.caption)
    }

    @ViewBuilder private func items(_ kinds: [CameraDiagram.Surface.Kind]) -> some View {
        ForEach(kinds, id: \.self) { kind in
            swatch(DiagramStyle.color(kind), DiagramStyle.name(kind))
        }
        swatch(DiagramStyle.lod, "LOD camera")
        swatch(DiagramStyle.streamed, DiagramStyle.streamedAreaName(diagram))
        if diagram.room != nil { swatch(DiagramStyle.shown, DiagramStyle.shownRegionName(diagram)) }
    }

    private func swatch(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 12, height: 3)
            Text(name).foregroundStyle(.secondary)
        }
    }
}

/// Fits side-view metres into a view: uniform scale, y up, centred.
struct DiagramFit {
    let scale: Double
    let centre: SIMD2<Double>
    let size: CGSize

    init(bounds: CameraDiagram.Bounds, size: CGSize) {
        self.size = size
        centre = bounds.centre
        scale = min(size.width / bounds.size.x, size.height / bounds.size.y)
    }

    func point(_ p: SIMD2<Double>) -> CGPoint {
        CGPoint(x: size.width / 2 + (p.x - centre.x) * scale,
                y: size.height / 2 - (p.y - centre.y) * scale)
    }

    func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { simd_distance(a, b) * scale }

    func rect(_ bounds: CameraDiagram.Bounds) -> CGRect {
        let a = point(bounds.min), b = point(bounds.max)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// The view's diagonal, in side-view metres.
    var reach: Double { hypot(size.width, size.height) / scale }

    func line(_ points: [SIMD2<Double>]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: point(first))
            for p in points.dropFirst() { path.addLine(to: point(p)) }
        }
    }

    /// The ground's far side: a surface closed round the Earth, or a wedge
    /// from it to the Earth's centre, whichever way the ground is turned.
    func ground(_ points: [SIMD2<Double>], centre: SIMD2<Double>, closes: Bool) -> Path {
        var path = line(points)
        if !closes { path.addLine(to: point(centre)) }
        path.closeSubpath()
        return path
    }

    /// A viewpoint's field of view, out past the edge of the view.
    func cone(_ viewpoint: CameraDiagram.Viewpoint) -> Path {
        guard let fieldOfView = viewpoint.fieldOfView else { return Path() }
        func edge(_ angle: Double) -> SIMD2<Double> {
            let d = viewpoint.direction
            let rotated = SIMD2(d.x * cos(angle) - d.y * sin(angle), d.x * sin(angle) + d.y * cos(angle))
            return viewpoint.position + rotated * reach * 2
        }
        var path = line([viewpoint.position, edge(fieldOfView / 2), edge(-fieldOfView / 2)])
        path.closeSubpath()
        return path
    }
}

enum DiagramStyle {
    static let lod = Color.purple
    static let shown = Color.teal
    static let streamed = Color.green
    static let placement = Color.orange

    /// What the host's content square is: a box (the volume's) shows exactly
    /// it; without one (the immersive space) it's for gestures and the
    /// ground sample.
    static func shownRegionName(_ diagram: CameraDiagram) -> String {
        diagram.inputs.containerSize != nil ? "shown region (the box)" : "content square (gestures, ground sample)"
    }

    static func streamedAreaName(_ diagram: CameraDiagram) -> String {
        guard diagram.room != nil, case .georeference = diagram.inputs.areaPolicy else {
            return "streamed area (to the horizon)"
        }
        return "streamed area"
    }

    static func color(_ kind: CameraDiagram.Surface.Kind) -> Color {
        switch kind {
        case .ellipsoid: .gray
        case .terrain: .brown
        case .placementGround: placement
        }
    }

    static func name(_ kind: CameraDiagram.Surface.Kind) -> String {
        switch kind {
        case .ellipsoid: "ellipsoid (h = 0)"
        case .terrain: "terrain"
        case .placementGround: "placement ground"
        }
    }

    static func stroke(_ kind: CameraDiagram.Surface.Kind, _ path: Path, in context: inout GraphicsContext) {
        let style: StrokeStyle = switch kind {
        case .ellipsoid: StrokeStyle(lineWidth: 1, dash: [2, 3])
        case .terrain: StrokeStyle(lineWidth: 2)
        case .placementGround: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
        }
        context.stroke(path, with: .color(color(kind)), style: style)
    }

    /// What the picture is drawn from: the window's render camera, or a room
    /// host's reference head pose (the code's design eye).
    static func viewerName(_ diagram: CameraDiagram) -> String {
        diagram.room == nil ? "render camera" : "reference head"
    }

    /// The navigation position (a dot with the camera pose's direction) and
    /// the viewer (a ring), joined if the placement separates them. The
    /// viewer is red underground.
    static func marker(camera: CameraDiagram.Viewpoint, viewer: CameraDiagram.Viewpoint, viewerName: String,
                       underground: Bool, fit: DiagramFit, in context: inout GraphicsContext) {
        let c = fit.point(camera.position), v = fit.point(viewer.position)
        let apart = hypot(c.x - v.x, c.y - v.y) > 4
        if apart {
            context.stroke(Path { $0.move(to: c); $0.addLine(to: v) }, with: .color(.secondary),
                           style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
        }
        let tip = CGPoint(x: c.x + camera.direction.x * 22, y: c.y - camera.direction.y * 22)
        context.stroke(Path { $0.move(to: c); $0.addLine(to: tip) }, with: .color(.primary), lineWidth: 1.5)
        context.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(.primary))
        let eyeColor: Color = underground ? .red : .green
        context.stroke(Path(ellipseIn: CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)),
                       with: .color(eyeColor), lineWidth: 2)
        let viewer = underground ? "\(viewerName) (underground)" : viewerName
        if apart {
            label("navigation position", at: c, in: &context)
            label(viewer, at: v, in: &context, below: true, color: eyeColor)
        } else {
            label("navigation position = \(viewer)", at: c, in: &context, color: eyeColor)
        }
    }

    static func cross(at p: CGPoint, in context: inout GraphicsContext) {
        context.stroke(Path { path in
            path.move(to: CGPoint(x: p.x - 4, y: p.y - 4)); path.addLine(to: CGPoint(x: p.x + 4, y: p.y + 4))
            path.move(to: CGPoint(x: p.x - 4, y: p.y + 4)); path.addLine(to: CGPoint(x: p.x + 4, y: p.y - 4))
        }, with: .color(.primary), lineWidth: 1.5)
    }

    static func diamond(at p: CGPoint, in context: inout GraphicsContext) {
        context.fill(Path { path in
            path.move(to: CGPoint(x: p.x, y: p.y - 4)); path.addLine(to: CGPoint(x: p.x + 4, y: p.y))
            path.addLine(to: CGPoint(x: p.x, y: p.y + 4)); path.addLine(to: CGPoint(x: p.x - 4, y: p.y))
            path.closeSubpath()
        }, with: .color(placement))
    }

    static func tick(at p: CGPoint, in context: inout GraphicsContext) {
        context.stroke(Path { $0.move(to: CGPoint(x: p.x, y: p.y - 4)); $0.addLine(to: CGPoint(x: p.x, y: p.y + 4)) },
                       with: .color(.secondary), lineWidth: 1.5)
    }

    static func label(_ text: String, at p: CGPoint, in context: inout GraphicsContext,
                      below: Bool = false, left: Bool = false, color: Color = .secondary) {
        context.draw(Text(text).font(.caption2).foregroundStyle(color),
                     at: CGPoint(x: p.x + (left ? -7 : 7), y: p.y + (below ? 9 : -9)),
                     anchor: left ? .trailing : .leading)
    }
}
