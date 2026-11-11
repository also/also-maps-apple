// Renders the figures in this directory from the app's own placement code
// and the camera diagram's views. From the repository root:
//
//   swiftc -O -parse-as-library -o /tmp/tilt-figures Sources/Navigation/*.swift \
//     Sources/MapPresentation.swift Sources/Diagrams/CameraDiagramView.swift docs/tilt-assist/make-figures.swift
//   /tmp/tilt-figures docs/tilt-assist/figures
//
// Nothing here restates the behavior: the heights shown are found from
// EyeLevelModel.tiltWeight, the hosts' geometry comes from MapPresentation,
// and the placement from EyeLevelModel.framing (through CameraDiagram). If
// the behavior changes, rerun this and the figures follow.

import AppKit
import Charts
import SwiftUI

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "figures")
let degrees = 180 / Double.pi

struct Host {
    let name: String
    let presentation: MapPresentation
    var room: RoomGeometry {
        guard case let .room(room) = presentation.geometry else { fatalError("not a room host") }
        return room
    }
    var containerSize: SIMD3<Double>? { presentation.host == .volume ? MapPresentation.volumeSize : nil }
}

let hosts = [Host(name: "Volume", presentation: .volume), Host(name: "Immersive", presentation: .immersive)]

/// The lowest height (metres above the ellipsoid) where the assist's weight
/// reaches `weight`, by bisection: the weight only grows with height.
func height(reaching weight: Double) -> Double {
    var low = 1.0, high = 40_000_000.0
    guard EyeLevelModel.tiltWeight(altitude: high) >= weight else { return high }
    for _ in 0..<100 {
        let mid = sqrt(low * high)
        if EyeLevelModel.tiltWeight(altitude: mid) >= weight { high = mid } else { low = mid }
    }
    return high
}

/// The three states the figures show: below where the tilt starts, halfway,
/// and where it's full.
struct Stage {
    let name: String
    let height: Double
}

let stages: [Stage] = {
    let start = height(reaching: 1e-6)
    return [Stage(name: "No tilt", height: start / 2),
            Stage(name: "Partial tilt", height: height(reaching: 0.5)),
            Stage(name: "Full tilt", height: height(reaching: 1))]
}()

/// Somewhere with nothing in particular below, facing north, over ground at
/// the ellipsoid. Pitch doesn't affect a room host's placement.
func camera(at height: Double) -> CameraPose {
    CameraPose(latitude: 45, longitude: -100, height: height, heading: 0, pitch: -.pi / 4)
}

func diagram(_ host: Host, _ stage: Stage) -> CameraDiagram {
    CameraDiagram(CameraDiagram.Inputs(camera: camera(at: stage.height), presentation: .room(host.room),
                                       terrainHeight: 0, groundHeight: 0, containerSize: host.containerSize))
}

func distance(_ metres: Double) -> String {
    metres < 1_000 ? String(format: "%.0f m", metres)
        : metres < 100_000 ? String(format: "%.1f km", metres / 1_000)
        : String(format: "%.0f km", metres / 1_000)
}

func scale(_ s: Double?) -> String {
    guard let s else { return "" }
    return "1 : \((1 / s).formatted(.number.precision(.significantDigits(3))))"
}

// MARK: Figures

struct RoomPanel: View {
    let host: Host
    let stage: Stage

    var body: some View {
        let d = diagram(host, stage)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(host.name): \(stage.name.lowercased())").font(.subheadline.weight(.semibold))
            CameraDiagramRoomView(diagram: d)
                .frame(width: 360, height: 260)
                .background(Color(white: 0.95))
            Text(String(format: "%@ up · weight %.2f · tilted %.0f° · %@",
                        distance(stage.height), d.tiltWeight, (d.room?.tilt ?? 0) * degrees, scale(d.scale)))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct Figure<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(16)
            .background(.white)
            .environment(\.colorScheme, .light)
    }
}

struct WeightChart: View {
    var body: some View {
        let low = log10(stages[0].height / 4), high = log10(stages[2].height * 4)
        let curve = stride(from: low, through: high, by: (high - low) / 200).map { exponent in
            (pow(10, exponent), EyeLevelModel.tiltWeight(altitude: pow(10, exponent)))
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Tilt weight against height above the ellipsoid").font(.headline)
            Chart {
                ForEach(curve.indices, id: \.self) { i in
                    LineMark(x: .value("Height (km)", curve[i].0 / 1_000), y: .value("Weight", curve[i].1))
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                ForEach(stages, id: \.name) { stage in
                    PointMark(x: .value("Height (km)", stage.height / 1_000),
                              y: .value("Weight", EyeLevelModel.tiltWeight(altitude: stage.height)))
                        .foregroundStyle(.black)
                        .symbolSize(40)
                        .annotation(position: .topLeading, spacing: 4) {
                            Text(stage.name).font(.caption).foregroundStyle(.secondary)
                        }
                }
            }
            .chartXScale(domain: pow(10, low) / 1_000...pow(10, high) / 1_000, type: .log)
            .chartXAxisLabel("height above the ellipsoid (km, log scale)")
            .chartYAxisLabel("weight")
            .chartYScale(domain: 0...1.1)
            .frame(width: 560, height: 240)
            Text(hosts.map { String(format: "%@ tilts %.0f° at full weight", $0.name, $0.room.fullTilt * degrees) }
                    .joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor func save(_ name: String, _ view: some View) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("couldn't render \(name)") }
    try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try! png.write(to: output.appendingPathComponent(name + ".png"))
    print(output.appendingPathComponent(name + ".png").path)
}

@main
struct MakeFigures {
    @MainActor static func main() {
        save("weight", Figure { WeightChart() })
        save("rooms", Figure {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                ForEach(stages, id: \.name) { stage in
                    GridRow {
                        ForEach(hosts, id: \.name) { host in RoomPanel(host: host, stage: stage) }
                    }
                }
            }
            CameraDiagramLegend(diagram: diagram(hosts[0], stages[0])).frame(width: 736)
        })
        for stage in stages {
            print("\(stage.name): \(distance(stage.height)), weight \(EyeLevelModel.tiltWeight(altitude: stage.height))")
        }
    }
}
