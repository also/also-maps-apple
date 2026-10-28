import SwiftUI

/// iPhone owns its navigation and safe-area layout; the shared scene owns
/// the camera and streaming. A new place creates a new scene identity.
struct PhoneMapView: View {
    @State private var selection = initialPlace
    @State private var showsPlaces = false

    private static var initialPlace: Place? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["ALSOMAPS_PLACE"],
           let place = PlaceLibrary.all.first(where: { $0.id == id }) {
            return place
        }
        if env["ALSOMAPS_VIEW"] != nil { return nil }
        return PlaceLibrary.all.first
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let preset = StaticView.fromEnvironment(defaultView: .ferry,
                                                         viewportSize: geometry.size)
                StaticMapView(view: selection.map {
                    StaticView.place($0, viewportSize: geometry.size, settings: preset.settings)
                } ?? preset, showsDiagnostics: false, creditLineLimit: nil)
                    .id(selection?.id ?? "environment")
            }
            .navigationTitle(selection?.name ?? "Also Maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Places", systemImage: "mappin.and.ellipse") {
                        showsPlaces = true
                    }
                }
            }
            .sheet(isPresented: $showsPlaces) {
                NavigationStack {
                    List(PlaceLibrary.all) { place in
                        Button {
                            selection = place
                            showsPlaces = false
                        } label: {
                            HStack {
                                Text(place.name)
                                Spacer()
                                if selection?.id == place.id {
                                    Image(systemName: "checkmark")
                                        .accessibilityLabel("Selected")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .navigationTitle("Places")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showsPlaces = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}
