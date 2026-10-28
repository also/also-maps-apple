import SwiftUI

/// A saved location is a static orbit on TV. Replacing the scene also drops
/// the old streamer and its camera, frame subscription and tile entities.
struct TVMapView: View {
    private static let viewportSize = CGSize(width: 1920, height: 1080)
    private let initialView = StaticView.fromEnvironment(defaultView: .ferry,
                                                         viewportSize: viewportSize)
    @State private var selection = initialPlace
    @State private var showsPlaces = false

    private static var initialPlace: Place? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["ALSOMAPS_PLACE"],
           let place = PlaceLibrary.all.first(where: { $0.id == id }) {
            return place
        }
        // Keep the explicit camera override for comparing the Mac views.
        if env["ALSOMAPS_VIEW"] != nil { return nil }
        return PlaceLibrary.all.first
    }

    var body: some View {
        StaticMapView(view: selection.map {
            StaticView.place($0, viewportSize: Self.viewportSize, settings: initialView.settings)
        } ?? initialView)
            .id(selection?.id ?? "environment")
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button {
                    showsPlaces = true
                } label: {
                    Label(selection?.name ?? "Places", systemImage: "mappin.and.ellipse")
                }
                .padding(.top, 50)
                .padding(.trailing, 60)
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
                    }
                    .navigationTitle("Places")
                }
            }
    }
}
