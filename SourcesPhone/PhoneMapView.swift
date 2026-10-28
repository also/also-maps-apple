import SwiftUI

/// The flying map on iPhone: drone-style sticks over the shared screen
/// map, with places in a sheet. The view owns safe-area layout; the map
/// owns the camera and streaming.
struct PhoneMapView: View {
    @State private var map = PhoneMapView.makeMap()
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

    /// Starts at ALSOMAPS_PLACE, the first place, or (with ALSOMAPS_VIEW)
    /// that preset's camera.
    private static func makeMap() -> ScreenMap {
        let preset = StaticView.fromEnvironment(defaultView: .ferry)
        if let place = initialPlace {
            return ScreenMap(place: place, settings: preset.settings)
        }
        return ScreenMap(camera: preset.cameraPose, settings: preset.settings)
    }

    var body: some View {
        NavigationStack {
            ScreenMapView(map: map, showsStatus: false, creditLineLimit: nil)
                .overlay(alignment: .bottom) {
                    DroneControls(map: map)
                        // Clear of the attribution along the bottom.
                        .padding(.bottom, 64)
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
                            map.go(to: place)
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
