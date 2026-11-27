import SwiftUI

/// Record, play, show and share a track, collapsed into one toolbar menu on
/// visionOS, iPhone and the Mac. A track follows the navigation position on
/// visionOS and the camera on iPhone and the Mac. While recording, Stop Recording sits in red
/// beside the menu, so the recorder can't run unnoticed.
struct TrackMenu: View {
    let tracks: TrackSession
    /// Plays the opened track, else the latest recording: the host's own
    /// start, which also resets its gestures and framing.
    let play: () -> Void
    let stopPlayback: () -> Void

    var body: some View {
        Group {
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
            }
            Menu {
                if !tracks.isRecording {
                    Button("Record Track", systemImage: "record.circle") {
                        tracks.startRecording()
                    }
                    .disabled(tracks.isPlaying)
                }
                Button(tracks.isPlaying ? "Stop Playback" : "Play Track",
                       systemImage: tracks.isPlaying ? "stop.fill" : "play.fill") {
                    tracks.isPlaying ? stopPlayback() : play()
                }
                .disabled(!tracks.canPlay)
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
            .help("Record, play, show or share the track")
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
