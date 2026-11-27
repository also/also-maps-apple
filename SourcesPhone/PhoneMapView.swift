import SwiftUI

/// The flying map on iPhone: drone-style sticks over the shared screen
/// map, with places in a sheet. The view owns safe-area layout; the map
/// owns the camera and streaming.
struct PhoneMapView: View {
    @State private var map = PhoneMapView.makeMap()
    @State private var selection = initialPlace
    @State private var showsPlaces = false
    /// The view being saved to My Map, while its name is chosen.
    @State private var savingPlace: PlaceToSave?
    @State private var search = PlaceSearch()
    @State private var showsSettings = false
    @Environment(\.scenePhase) private var scenePhase

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
        let preset = StaticView.fromEnvironment(defaultView: .ferry, settings: .load())
        if let place = initialPlace {
            return ScreenMap(place: place, settings: preset.settings)
        }
        return ScreenMap(camera: preset.cameraPose, settings: preset.settings)
    }

    var body: some View {
        NavigationStack {
            MetalOptionMapView(map: map, creditLineLimit: nil)
                // Over the map, under the sticks, the same size as the scene.
                .overlay {
                    TouchSurface(map: map)
                        .ignoresSafeArea()
                }
                .overlay(alignment: .bottom) {
                    // The track has the camera while it plays.
                    if !map.tracks.isPlaying {
                        DroneControls(map: map)
                            // Clear of the attribution along the bottom.
                            .padding(.bottom, 64)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: map.tracks.isPlaying)
            // No title: you fly away from the place you picked. The bar is
            // just the Places button, over the map.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                TrackStatus(tracks: map.tracks)
            }
            // Write out the recording in case the app is suspended.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { map.tracks.flush() }
            }
            .onDisappear { map.tracks.flush() }
            .opensPlaces(go: { place in
                selection = place
                map.go(to: place)
                showsPlaces = false
            }, imported: { showsPlaces = true })
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    trackControls
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        showsSettings = true
                    }
                    Button("Save to My Map", systemImage: "star") {
                        savingPlace = PlaceToSave(place: map.currentPlace(id: UUID().uuidString, name: ""),
                                                  viewCenter: map.viewCenter)
                    }
                    TracesMenu(streaming: map.streaming, tracks: map.tracks) { place in
                        selection = nil
                        map.go(to: place)
                    }
                    Button("Places", systemImage: "mappin.and.ellipse") {
                        showsPlaces = true
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                @Bindable var map = map
                SettingsView(settings: $map.settings) { showsSettings = false }
            }
            .sheet(item: $savingPlace) { saving in
                SavePlaceView(saving: saving) { savingPlace = nil }
                    .frame(maxWidth: .infinity)
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showsPlaces, onDismiss: {
                search.cancelChoice()
                search = PlaceSearch()
            }) {
                NavigationStack {
                    PlacesList(search: search, near: { [map] in map.navigation.camera.coordinate },
                               selectedID: selection?.id) { place in
                        selection = place
                        map.go(to: place)
                        showsPlaces = false
                    }
                    .placeSearchable($search.query, if: map.settings.tileSource.showsGoogleTiles)
                    .onChange(of: map.settings.tileSource.showsGoogleTiles, initial: true) {
                        search.searchesGoogle = $1
                    }
                    .navigationTitle("Places")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showsPlaces = false }
                        }
                        ToolbarItem(placement: .primaryAction) { PlacesFileMenu() }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Tracks

    /// Record, play, show and share the track, in the same menu as on visionOS.
    private var trackControls: some View {
        TrackMenu(tracks: map.tracks, play: map.startPlayback, stopPlayback: map.tracks.stopPlayback)
    }
}

private extension View {
    /// The search field, only while the map shows Google's tiles; Google's
    /// terms don't allow its places over another provider's map.
    @ViewBuilder func placeSearchable(_ query: Binding<String>, if enabled: Bool) -> some View {
        if enabled {
            searchable(text: query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Places")
                .autocorrectionDisabled()
        } else {
            self
        }
    }
}
