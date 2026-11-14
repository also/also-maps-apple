import SwiftUI

/// Record, play, show and share a track, collapsed into one toolbar menu on
/// visionOS and iPhone. A track follows the navigation position on visionOS
/// and the camera on iPhone. The label turns red while recording,
/// since the menu otherwise hides that the recorder is running.
struct TrackMenu: View {
    let tracks: TrackSession
    /// Plays the latest track: the host's own start, which also resets its
    /// gestures and framing.
    let play: () -> Void
    let stopPlayback: () -> Void

    var body: some View {
        Menu {
            Button(tracks.isRecording ? "Stop Recording" : "Record Track",
                   systemImage: tracks.isRecording ? "stop.circle.fill" : "record.circle") {
                tracks.isRecording ? tracks.stopRecording() : tracks.startRecording()
            }
            .disabled(tracks.isPlaying)
            Button(tracks.isPlaying ? "Stop Playback" : "Play Track",
                   systemImage: tracks.isPlaying ? "stop.fill" : "play.fill") {
                tracks.isPlaying ? stopPlayback() : play()
            }
            .disabled(tracks.isRecording || tracks.latestTrack == nil)
            Button(tracks.showsTrack ? "Hide Track" : "Show Track",
                   systemImage: tracks.showsTrack ? "eye.slash" : "eye") {
                tracks.showsTrack.toggle()
            }
            if let track = tracks.latestTrack {
                ShareLink(item: track) {
                    Label("Share Track", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Label("Track", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        }
        .tint(tracks.isRecording ? .red : nil)
        .help("Record, play, show or share the track")
    }
}
