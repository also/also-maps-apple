import SwiftUI

/// The numbers behind a CameraDiagram, as a grid of rows.
struct CameraDiagramReadouts: View {
    let diagram: CameraDiagram

    var body: some View {
        let d = diagram
        let camera = d.inputs.camera
        let degrees = 180 / Double.pi
        let viewer = DiagramStyle.viewerName(d).capitalizedFirst
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Navigation position", String(format: "%.4f°, %.4f°", camera.latitude, camera.longitude))
            row("Height (ellipsoid)", Self.distance(camera.height))
            row("Heading, pitch", String(format: "%.1f°, %.1f°", camera.heading * degrees, camera.pitch * degrees))
            row("Terrain height", Self.distance(d.inputs.terrainHeight))
            if d.room != nil { row("Placement ground height", Self.distance(d.inputs.groundHeight)) }
            Divider().gridCellUnsizedAxes(.horizontal)
            row("Position above terrain", Self.distance(d.cameraAltitude))
            row("\(viewer) above terrain", Self.distance(d.viewerAltitude), color: d.viewerAltitude < 0 ? .red : nil)
            if let room = d.room {
                row("Tilt", String(format: "%.0f%% of full, %.0f°", d.tiltWeight * 100, room.tilt * degrees))
            }
            if let scale = d.scale {
                row("Scale", "1 : \((1 / scale).formatted(.number.precision(.significantDigits(3))))")
            }
            if let rho = d.shownRadius {
                row(d.inputs.containerSize == nil ? "Content square half-width" : "Shown half-width", Self.distance(rho))
            }
            row(d.inputs.heldStreaming == nil ? "Streamed half-width" : "Streamed half-width (held)",
                Self.distance(d.streamingRadius))
            if let range = d.rangeToGeoreference, let ground = d.groundDistanceToGeoreference {
                row("View center: range, along ground", "\(Self.distance(range)), \(Self.distance(ground))")
            } else {
                row("View center", "none: the view ray misses")
            }
            row("Horizon, along ground", Self.distance(d.horizonDistance))
            if let fieldOfView = d.viewer.fieldOfView {
                row("LOD field of view", String(format: "%.0f°", fieldOfView * degrees))
            }
        }
    }

    private func row(_ name: String, _ value: String, color: Color? = nil) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(color ?? .primary)
        }
    }

    static func distance(_ meters: Double) -> String {
        abs(meters) < 1_000
            ? "\(meters.formatted(.number.precision(.fractionLength(0)))) m"
            : "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
