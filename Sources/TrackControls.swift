import SwiftUI

/// Record a track, and stop recording or playback, in a screen's toolbar on
/// visionOS, iPhone and the Mac; the Traces panel lists the recordings to
/// show, play and share. A track follows the navigation position on visionOS
/// and the camera on iPhone and the Mac. While recording, Stop Recording is
/// red, so the recorder can't run unnoticed.
struct TrackControls: View {
    let tracks: TrackSession
    /// The host's own stop, which also resets its ground estimates.
    let stopPlayback: () -> Void

    var body: some View {
        if tracks.isRecording {
            // The icon itself is red: visionOS toolbars ignore tint.
            Button {
                tracks.stopRecording()
            } label: {
                Label {
                    Text("Stop Recording")
                } icon: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                }
            }
            .help("Stop recording the track")
        } else if tracks.isPlaying {
            Button("Stop Playback", systemImage: "stop.fill", action: stopPlayback)
                .help("Stop flying the track")
        } else {
            Button("Record Track", systemImage: "record.circle") {
                tracks.startRecording()
            }
            .help("Record the camera's track to a file in Files")
        }
    }
}

/// What the track is doing, in a capsule over the top of a screen map
/// (iPhone and the Mac); nothing while it's idle.
struct TrackStatus: View {
    let tracks: TrackSession

    var body: some View {
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
