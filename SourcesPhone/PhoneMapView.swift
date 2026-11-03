import SwiftUI

/// The flying map on iPhone: drone-style sticks over the shared screen
/// map, with places in a sheet. The view owns safe-area layout; the map
/// owns the camera and streaming.
struct PhoneMapView: View {
    @State private var map = PhoneMapView.makeMap()
    @State private var selection = initialPlace
    @State private var showsPlaces = false
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
            ScreenMapView(map: map, creditLineLimit: nil)
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
                trackStatus
            }
            // Write out the recording in case the app is suspended.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { map.tracks.flush() }
            }
            .onDisappear { map.tracks.flush() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    trackControls
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        showsSettings = true
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

    // MARK: Tracks

    /// Record, play, show and share the camera's track, as on visionOS.
    @ViewBuilder private var trackControls: some View {
        let tracks = map.tracks
        Button(tracks.isRecording ? "Stop Recording" : "Record Track",
               systemImage: tracks.isRecording ? "stop.circle.fill" : "record.circle") {
            tracks.isRecording ? tracks.stopRecording() : tracks.startRecording()
        }
        .tint(tracks.isRecording ? .red : nil)
        .disabled(tracks.isPlaying)
        Button(tracks.isPlaying ? "Stop Playback" : "Play Track",
               systemImage: tracks.isPlaying ? "stop.fill" : "play.fill") {
            tracks.isPlaying ? tracks.stopPlayback() : map.startPlayback()
        }
        .disabled(tracks.isRecording || tracks.latestTrack == nil)
        Menu("Track", systemImage: "ellipsis.circle") {
            Toggle("Show Track", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                   isOn: Binding(get: { tracks.showsTrack }, set: { tracks.showsTrack = $0 }))
            if let track = tracks.latestTrack {
                ShareLink(item: track) {
                    Label("Share Track", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    /// What the track is doing, under the bar.
    @ViewBuilder private var trackStatus: some View {
        let tracks = map.tracks
        if tracks.isRecording || tracks.isPlaying {
            Text(tracks.isRecording
                 ? "Recording track"
                 : "Playing track · \(TrackSession.minutes(tracks.playbackElapsed)) / \(TrackSession.minutes(tracks.playbackDuration))")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: .capsule)
                .foregroundStyle(.white)
                .padding(.top, 4)
        }
    }
}
