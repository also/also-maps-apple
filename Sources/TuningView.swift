import SwiftUI

/// Live streaming knobs, for trying trade-offs without rebuilding. Changes
/// apply on the next frame and are remembered between launches.
struct TuningView: View {
    static let windowID = "tuning"

    @Environment(MapModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var stateNote: String?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Tiles drawn", value: "\(model.streaming.stats.renderedTiles)")
                    LabeledContent("Entities loaded", value: "\(model.streaming.stats.entities)")
                    LabeledContent("Requests", value: "\(model.streaming.stats.cacheHits) cached, \(model.streaming.stats.revalidated) revalidated, \(model.streaming.stats.networkLoads) downloaded")
                    LabeledContent("Downloaded", value: String(format: "%.1f MB", model.streaming.stats.networkMegabytes))
                    LabeledContent("Load progress", value: "\(Int(model.streaming.loadProgress))%")
                }

                Section {
                    Picker("Tiles", selection: $model.settings.tileSource) {
                        ForEach(TileSource.allCases) { source in
                            Text(source.name).tag(source)
                        }
                    }
                    Text("Cesium ion sources need CESIUM_ION_TOKEN in Config/Secrets.xcconfig.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Source")
                }

                Section {
                    Toggle("Limit reach", isOn: $model.settings.limitsImmersiveReach)
                    Text("Immersive streams everything you could see, out to the horizon. Turn this on to stream less.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.settings.limitsImmersiveReach {
                        setting("Reach", value: $model.settings.immersiveReach, in: 5...100, step: 5,
                                format: { String(format: "%.0f× height", $0) },
                                hint: "How far around you to stream, in multiples of your height above the ground.")
                    }
                    setting("Detail", value: $model.settings.detail, in: 2...64, step: 1,
                            format: { "SSE \(Int($0))" },
                            hint: "Lower is sharper, with more tiles. Applies to what the LOD camera sees.")
                    setting("Outer detail", value: $model.settings.outerDetail, in: 8...256, step: 4,
                            format: { "SSE \(Int($0))" },
                            hint: "Same, for tiles outside the LOD camera's view, which is most of an expanded region.")
                } header: {
                    Text("Coverage and resolution")
                }

                Section {
                    setting("Parallel uploads", value: $model.settings.uploadConcurrency, in: 1...12, step: 1,
                            format: { "\(Int($0))" },
                            hint: "Tiles turned into RealityKit resources at once, off the main thread. Higher fills in faster.")
                    setting("Simultaneous loads", value: $model.settings.simultaneousLoads, in: 4...64, step: 2,
                            format: { "\(Int($0))" },
                            hint: "Concurrent tile requests.")
                    setting("Cache", value: $model.settings.cacheMegabytes, in: 128...4096, step: 128,
                            format: { "\(Int($0)) MB" },
                            hint: "Loaded tiles kept around before unloading.")
                    Toggle("Forbid holes", isOn: $model.settings.forbidHoles)
                } header: {
                    Text("Streaming")
                }

                Section {
                    Picker("Turn and zoom around", selection: $model.settings.keyboardTurnPivot) {
                        Text("Map centre").tag(StreamingSettings.TurnPivot.center)
                        Text("Where you are").tag(StreamingSettings.TurnPivot.viewer)
                    }
                    Text("Where you are keeps the ground beneath you fixed, so zooming is moving straight up or down and turning is turning on the spot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Logarithmic: 20 km … 10,000 km (about a hemisphere).
                    setting("Zoom-out limit",
                            value: Binding(
                                get: { log10(model.settings.zoomOutLimitKilometres) },
                                set: { model.settings.zoomOutLimitKilometres = pow(10, $0) }),
                            in: log10(20)...4, step: 0.05,
                            format: { Self.distance(pow(10, $0)) },
                            hint: "Half-width of the widest view. Past 50 km the ground is placed by the Earth's curve instead of sampling terrain.")
                } header: {
                    Text("Controls")
                }

                Section {
                    Toggle("Full immersion", isOn: $model.fullImmersion)
                    Text("Immersive modes show only the map, with no passthrough or environment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Human scale (test)", isOn: $model.humanScale)
                    Text("The world stays 1:1 at every altitude, with the ground as far below you as your height. Gestures don't suit it yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Immersion")
                }

                Section {
                    Toggle("Show pivot and centre markers", isOn: $model.showsDebugMarkers)
                    Text("Red: the point turns and zooms rotate around. Blue: the map's centre.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Show tile bounds", isOn: $model.showsTileBounds)
                    Text("Each drawn tile's box: cyan inside the LOD camera's view, orange outside. Yellow: the area of interest. Pink: the LOD camera's view; white: its view direction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Copy View State") {
                        let json = model.captureState().json()
                        UIPasteboard.general.string = json
                        print("[AlsoMaps] view state: \(json)")
                        stateNote = "Copied (also printed to the console)."
                    }
                    Button("Restore from Clipboard") {
                        guard let text = UIPasteboard.general.string else {
                            stateNote = "The clipboard doesn't hold a view state."
                            return
                        }
                        let state: MapViewState
                        do {
                            state = try MapViewState.parse(text)
                        } catch {
                            stateNote = error.localizedDescription
                            return
                        }
                        Task {
                            await VolumeView.restore(state, model: model,
                                                        open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
                            stateNote = "Restored."
                        }
                    }
                    if let stateNote {
                        Text(stateNote).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Debugging")
                }

                Section {
                    Button("Reset to Defaults") {
                        model.settings = .default
                    }
                    .disabled(model.settings == .default)
                }
            }
            .navigationTitle("Tuning")
        }
    }

    private static func distance(_ kilometres: Double) -> String {
        kilometres < 100 ? "\(Int(kilometres.rounded())) km"
            : kilometres < 1000 ? "\(Int((kilometres / 10).rounded()) * 10) km"
            : "\((kilometres / 100).rounded() / 10) thousand km"
    }

    private func setting(_ title: String,
                         value: Binding<Double>,
                         in range: ClosedRange<Double>,
                         step: Double,
                         format: @escaping (Double) -> String,
                         hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: format(value.wrappedValue))
            Slider(value: value, in: range, step: step)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
