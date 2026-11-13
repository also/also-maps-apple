import SwiftUI

/// The app's settings, by category in a sidebar: a window on visionOS, the
/// Settings window on the Mac, a sheet on iPhone. Changes apply right away
/// and are remembered between launches. Categories that only make sense
/// for visionOS's map (immersion, detail, debugging) only appear there.
struct SettingsView: View {
    static let windowID = "settings"

    @Binding var settings: StreamingSettings
    /// Shows a Done button that calls this, for a sheet.
    var onDone: (() -> Void)?

    @AppStorage(ViewPreferences.showsStatsKey) private var showsStats = false
    @AppStorage(ViewPreferences.drawsWithMetalKey) private var drawsWithMetal = false
    #if os(iOS)
    /// On iPhone the list comes first; nothing picked shows General on iPad.
    @State private var category: Category?
    #else
    @State private var category: Category? = .general
    #endif
    #if os(visionOS)
    @Environment(MapModel.self) private var model
    @AppStorage(ViewPreferences.showsDebugControlsKey) private var showsDebugControls = false
    #endif

    init(settings: Binding<StreamingSettings>, onDone: (() -> Void)? = nil) {
        _settings = settings
        self.onDone = onDone
    }

    enum Category: String, CaseIterable, Identifiable {
        case general
        #if os(visionOS)
        case immersion
        case detail
        #endif
        case keys
        case advanced

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            #if os(visionOS)
            case .immersion: "Immersion"
            case .detail: "Detail"
            #endif
            case .keys: "Keys"
            case .advanced: "Advanced"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            #if os(visionOS)
            case .immersion: "visionpro"
            case .detail: "square.grid.3x3"
            #endif
            case .keys: "key"
            case .advanced: "wrench.and.screwdriver"
            }
        }
    }

    var body: some View {
        // The sidebar is the only navigation, so it always shows (iPhone
        // still shows one column at a time).
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(Category.allCases, selection: $category) { category in
                Label(category.title, systemImage: category.systemImage)
            }
            .navigationTitle("Settings")
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
            #endif
        } detail: {
            NavigationStack {
                page(for: category ?? .general)
            }
        }
    }

    @ViewBuilder private func page(for category: Category) -> some View {
        switch category {
        case .general: general
        #if os(visionOS)
        case .immersion: immersion
        case .detail: detailSettings
        #endif
        case .keys: KeysView()
        case .advanced: advanced
        }
    }

    static let termsURL = URL(string: "https://maps.also.dev/terms/")!
    static let googleMapsTermsURL = URL(string: "https://maps.google.com/help/terms_maps/")!
    static let googlePrivacyURL = URL(string: "https://policies.google.com/privacy")!

    // MARK: Categories

    private var general: some View {
        Form {
            Section {
                Picker("Tiles", selection: $settings.tileSource) {
                    ForEach(TileSource.allCases) { source in
                        Text(source.name).tag(source)
                    }
                }
            }

            Section {
                Toggle("Show stats", isOn: $showsStats)
            } footer: {
                Text("Tiles drawn, load progress and requests, shown over the map.")
            }

            #if !os(tvOS)
            Section {
                Toggle("Draw with Metal", isOn: $drawsWithMetal)
            } footer: {
                #if os(visionOS)
                Text("Draws the immersive map with the app's own Metal renderer instead of RealityKit, always in full immersion, with real depth. Takes effect the next time you open Immersive. Pinching the map, tracks and tile bounds aren't available with it.")
                #else
                Text("Draws the map with the app's own Metal renderer instead of RealityKit. Tracks and tile bounds aren't drawn with it.")
                #endif
            }
            #endif

            // Google Maps Platform Terms §3.2.2(a): the app's terms must say
            // it includes Google Maps content, under Google's terms and privacy policy.
            Section {
                Link("Terms of Use", destination: Self.termsURL)
                Link("Google Maps Terms", destination: Self.googleMapsTermsURL)
                Link("Google Privacy Policy", destination: Self.googlePrivacyURL)
            } header: {
                Text("Terms")
            } footer: {
                Text("Also Maps includes Google Maps features and content. Their use is subject to the Google Maps/Google Earth Additional Terms of Service and the Google Privacy Policy.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    #if os(visionOS)
    private var immersion: some View {
        @Bindable var model = model
        return Form {
            Section {
                Toggle("Full immersion", isOn: $model.fullImmersion)
            } footer: {
                Text("Immersive modes show only the map, with no passthrough or environment.")
            }

            Section {
                Toggle("Limit reach", isOn: $settings.limitsImmersiveReach)
                if settings.limitsImmersiveReach {
                    setting("Reach", value: $settings.immersiveReach, in: 5...100, step: 5,
                            format: { String(format: "%.0f× height", $0) },
                            hint: "How far around you to stream, in multiples of your height above the ground.")
                }
            } footer: {
                Text("Immersive streams everything you could see, out to the horizon. Turn this on to stream less.")
            }

            Section {
                Toggle("Human scale (test)", isOn: $model.humanScale)
            } footer: {
                Text("The world stays 1:1 at every altitude, with the ground as far below you as your height. Gestures don't suit it yet.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Immersion")
    }

    private var detailSettings: some View {
        Form {
            Section {
                setting("Detail", value: $settings.detail, in: 2...64, step: 1,
                        format: { "SSE \(Int($0))" },
                        hint: "Lower is sharper, with more tiles. Applies to what the LOD camera sees.")
                setting("Outer detail", value: $settings.outerDetail, in: 8...256, step: 4,
                        format: { "SSE \(Int($0))" },
                        hint: "Same, for tiles outside the LOD camera's view, which is most of an expanded region.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Detail")
    }
    #endif

    private var advanced: some View {
        Form {
            Section {
                setting("Parallel uploads", value: $settings.uploadConcurrency, in: 1...12, step: 1,
                        format: { "\(Int($0))" },
                        hint: "Tiles turned into RealityKit resources at once, off the main thread. Higher fills in faster.")
                setting("Simultaneous loads", value: $settings.simultaneousLoads, in: 4...64, step: 2,
                        format: { "\(Int($0))" },
                        hint: "Concurrent tile requests.")
                setting("Cache", value: $settings.cacheMegabytes, in: 128...4096, step: 128,
                        format: { "\(Int($0)) MB" },
                        hint: "Loaded tiles kept around before unloading.")
                Toggle("Forbid holes", isOn: $settings.forbidHoles)
            } header: {
                Text("Streaming")
            }

            #if os(visionOS)
            debugging
            #endif

            if let build = BuildInfo.current {
                BuildInfoSection(info: build)
            }

            Section {
                Button("Reset to Defaults") {
                    settings = defaults
                }
                .disabled(settings == defaults)
            } footer: {
                Text("Returns every setting except Show stats, Draw with Metal and your keys to how the app ships.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
    }

    /// `StreamingSettings.default`, but on a screen the map sets detail from
    /// its pixels, so it isn't a setting there.
    private var defaults: StreamingSettings {
        var defaults = StreamingSettings.default
        #if !os(visionOS)
        defaults.detail = settings.detail
        defaults.outerDetail = settings.outerDetail
        #endif
        return defaults
    }

    #if os(visionOS)
    @ViewBuilder private var debugging: some View {
        Section {
            Toggle("Show debug controls", isOn: $showsDebugControls)
        } header: {
            Text("Debugging")
        } footer: {
            Text("Adds a wrench to the map's toolbar that opens these controls beside the map, to change while you move it.")
        }
        Section {
            DebugControls(showsNotes: true)
        }
    }
    #endif

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
