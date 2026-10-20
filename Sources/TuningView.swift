import SwiftUI

/// Live streaming knobs, for trying trade-offs without rebuilding. Changes
/// apply on the next frame and are remembered between launches.
struct TuningView: View {
    static let windowID = "tuning"

    @Environment(MapVolumeModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Tiles drawn", value: "\(model.stats.renderedTiles)")
                    LabeledContent("Entities loaded", value: "\(model.stats.entities)")
                    LabeledContent("Load progress", value: "\(Int(model.loadProgress))%")
                }

                Section {
                    setting("Region", value: $model.settings.immersiveRegion, in: 1...10, step: 0.5,
                            format: { String(format: "%.1f×", $0) },
                            hint: "How far past the volume-sized square to stream. Floor modes only.")
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
                    setting("Upload budget", value: $model.settings.uploadBudgetMilliseconds, in: 1...30, step: 1,
                            format: { "\(Int($0)) ms/frame" },
                            hint: "Higher fills in faster but hitches more.")
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
                    Picker("Keyboard turns around", selection: $model.settings.keyboardTurnPivot) {
                        Text("Centre").tag(StreamingSettings.TurnPivot.center)
                        Text("Front edge").tag(StreamingSettings.TurnPivot.frontEdge)
                    }
                    Text("Front edge turns about the middle of the map's near edge, so Q/E with W feels like flying.")
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
