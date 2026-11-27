import Foundation
import Observation
import RealityKit

/// Tracks for one map, on any platform: recording the camera to a file,
/// drawing tracks as tubes, and flying along one. TraceLibrary says which
/// tracks are shown and which to play. The map feeds it the camera each
/// frame and, while it plays, takes the camera from it.
@MainActor
@Observable
final class TrackSession {
    /// Where tracks are saved: the app's Documents folder, which the Files
    /// app shows. See CameraTrack for the format.
    static let directory = URL.documentsDirectory

    /// The recording in progress, sampling the camera each frame.
    private(set) var recorder: TrackRecorder?
    var isRecording: Bool { recorder != nil }
    /// Called when a recording starts or stops, so the Traces list can
    /// show it.
    @ObservationIgnored var recordingsChanged: (() -> Void)?

    /// The tubes; it goes in the map's scene.
    @ObservationIgnored let root = Entity()
    /// The shown tracks' tubes, by TraceEntry ID.
    @ObservationIgnored private var overlays: [String: TrackOverlay] = [:]
    /// The recording in progress, drawn as it grows when it's shown.
    @ObservationIgnored private let recordingOverlay = TrackOverlay()

    /// The track being played back, driving the camera from its first
    /// sample to its last, by the frame clock.
    private var playback: TrackPlayback?
    /// Seconds into the track played, advanced every frame.
    @ObservationIgnored private(set) var playbackTime: TimeInterval = 0
    /// Whole seconds played and in all, for status lines (observed, so they
    /// change once a second rather than every frame).
    private(set) var playbackElapsed = 0
    private(set) var playbackDuration = 0
    var isPlaying: Bool { playback != nil }

    init() {
        root.addChild(recordingOverlay.root)
    }

    // MARK: Recording

    /// The TraceEntry ID of the recording in progress.
    var recordingID: String? {
        recorder.map { TraceEntry.recordingID(fileName: $0.url.lastPathComponent) }
    }

    func startRecording() {
        guard recorder == nil, playback == nil else { return }
        do {
            let recorder = try TrackRecorder(directory: Self.directory)
            self.recorder = recorder
            recordingOverlay.path = nil
            print("[AlsoMaps] recording track to \(recorder.url.path)")
            recordingsChanged?()
        } catch {
            print("[AlsoMaps] couldn't start a track: \(error)")
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        recorder.finish()
        self.recorder = nil
        recordingOverlay.path = nil
        recordingOverlay.isEnabled = false
        print("[AlsoMaps] track finished: \(recorder.sampleCount) samples in \(recorder.url.lastPathComponent)")
        recordingsChanged?()
    }

    /// Records `camera` if a sample is due, and draws it.
    func record(_ camera: CameraPose) {
        if let sample = recorder?.record(camera) {
            recordingOverlay.append(sample)
        }
    }

    /// The camera jumped (a place, a restored view): the track starts a new
    /// segment rather than drawing a line across.
    func markJump() { recorder?.markJump() }

    /// Writes buffered samples out, for when the app may be suspended.
    func flush() { recorder?.flush() }

    // MARK: Drawing

    /// Draws these tracks as tubes, by TraceEntry ID, and no others. The
    /// recording in progress is drawn as it grows if its ID is among
    /// `shownIDs`; it isn't in `tracks`, as it's still being written.
    func show(_ tracks: [String: Track], shownIDs: Set<String>) {
        for (id, overlay) in overlays where tracks[id] == nil {
            overlay.root.removeFromParent()
            overlays[id] = nil
        }
        for (id, track) in tracks where overlays[id] == nil {
            let overlay = TrackOverlay()
            overlay.path = TrackPath(samples: track.samples)
            overlay.isEnabled = true
            root.addChild(overlay.root)
            overlays[id] = overlay
        }
        recordingOverlay.isEnabled = recordingID.map(shownIDs.contains) ?? false
    }

    /// Places the tubes for this frame's georeference, with the tube radius
    /// in the world (TrackOverlay.update).
    func update(georeference: Georeference, worldRadius: Double) {
        recordingOverlay.update(georeference: georeference, worldRadius: worldRadius)
        for overlay in overlays.values {
            overlay.update(georeference: georeference, worldRadius: worldRadius)
        }
    }

    // MARK: Playback

    /// Starts `track` from the start and returns its first pose, or nil if
    /// there's nothing to play.
    func startPlayback(_ track: Track) -> CameraPose? {
        guard playback == nil, recorder == nil else { return nil }
        guard let played = TrackPlayback(track) else {
            print("[AlsoMaps] track \(track.name) has no samples")
            return nil
        }
        playback = played
        playbackTime = 0
        playbackElapsed = 0
        playbackDuration = Int(played.duration.rounded(.up))
        print("[AlsoMaps] playing track \(track.name): \(played.samples.count) samples, \(String(format: "%.1f", played.duration)) s")
        return played.pose(at: 0)
    }

    /// Advances playback by `deltaTime` and returns the camera then, or nil
    /// if nothing is playing. Playback stops by itself at the end, leaving
    /// the last pose.
    func advancePlayback(deltaTime: Double) -> CameraPose? {
        guard let playback else { return nil }
        playbackTime = min(playbackTime + deltaTime, playback.duration)
        let elapsed = Int(playbackTime)
        if playbackElapsed != elapsed { playbackElapsed = elapsed }
        let pose = playback.pose(at: playbackTime)
        if playbackTime >= playback.duration { stopPlayback() }
        return pose
    }

    func stopPlayback() {
        guard playback != nil else { return }
        playback = nil
        #if DEBUG
        print("[AlsoMaps] track playback stopped at \(String(format: "%.1f", playbackTime)) s")
        #endif
    }

    /// "m:ss", for status lines.
    static func minutes(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
