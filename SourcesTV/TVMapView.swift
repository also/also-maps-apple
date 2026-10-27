import SwiftUI

/// A saved location is a static orbit on TV. Replacing the scene also drops
/// the old streamer and its camera, frame subscription and tile entities.
struct TVMapView: View {
    @State private var selection = initialPlace
    @State private var showsPlaces = false

    private static var initialPlace: Place? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["MAPVOLUME_PLACE"],
           let place = PlaceLibrary.all.first(where: { $0.id == id }) {
            return place
        }
        // Keep the explicit camera override for comparing the Mac views.
        if env["MAPVOLUME_VIEW"] != nil { return nil }
        return PlaceLibrary.all.first
    }

    var body: some View {
        MapWindowView(view: selection.map(StaticView.place) ?? .fromEnvironment())
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

extension StaticView {
    static func place(_ place: Place) -> StaticView {
        let radius = max(place.radius, 50)
        let heading = place.heading * .pi / 180
        var lod = LODCamera.orbit(heading: heading, elevation: .pi / 4,
                                  distance: radius * 2.5)
        lod.aspect = 16.0 / 9.0
        return StaticView(name: place.name,
                          inputs: StreamingInputs(anchor: StreamingAnchor(coordinate: place.coordinate),
                                                  lod: lod,
                                                  regionHeading: heading,
                                                  streamingRadius: radius),
                          settings: StaticView.fromEnvironment().settings,
                          windowSize: CGSize(width: 1920, height: 1080),
                          near: 1, far: Float(max(100_000, radius * 20)),
                          samplesGround: true)
    }
}
