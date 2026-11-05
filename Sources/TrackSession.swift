import Foundation
import Observation

/// Camera tracks for one map, on any platform: recording the camera to a
/// file, drawing the track being recorded (or the latest one) as a tube,
/// and playing the latest one back in real time. The map feeds it the
/// camera each frame and, while it plays, takes the camera from it.
@MainActor
@Observable
final class TrackSession {
    /// Where tracks are saved: the app's Documents folder, which the Files
    /// app shows. See CameraTrack for the format.
    static let directory = URL.documentsDirectory

    /// The recording in progress, sampling the camera each frame.
    private(set) var recorder: TrackRecorder?
    /// The most recent track file, finished or in progress.
    private(set) var latestTrack: URL? = TrackRecorder.latestTrack(in: directory)
    var isRecording: Bool { recorder != nil }

    /// The tube; its root goes in the map's scene.
    @ObservationIgnored let overlay = TrackOverlay()

    /// The track being played back, driving the camera from its first
    /// sample to its last in real time, by the frame clock.
    private var playback: TrackPlayback?
    /// Seconds into the track played, advanced every frame.
    @ObservationIgnored private(set) var playbackTime: TimeInterval = 0
    /// Whole seconds played and in all, for status lines (observed, so they
    /// change once a second rather than every frame).
    private(set) var playbackElapsed = 0
    private(set) var playbackDuration = 0
    var isPlaying: Bool { playback != nil }

    /// `ALSOMAPS_TRACK=<path to a track file>` shows that track at launch,
    /// for checking the drawing where there's no track UI (the Mac).
    init() {
        guard let path = ProcessInfo.processInfo.environment["ALSOMAPS_TRACK"], !path.isEmpty else { return }
        do {
            overlay.path = try TrackPath(contentsOf: URL(fileURLWithPath: path))
            showsTrack = true
        } catch {
            print("[AlsoMaps] couldn't read track \(path): \(error)")
        }
    }

    // MARK: Recording

    func startRecording() {
        guard recorder == nil, playback == nil else { return }
        do {
            let recorder = try TrackRecorder(directory: Self.directory)
            self.recorder = recorder
            latestTrack = recorder.url
            overlay.path = nil  // Drawn as it's recorded.
            print("[AlsoMaps] recording track to \(recorder.url.path)")
        } catch {
            print("[AlsoMaps] couldn't start a track: \(error)")
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        recorder.finish()
        self.recorder = nil
        print("[AlsoMaps] track finished: \(recorder.sampleCount) samples in \(recorder.url.lastPathComponent)")
    }

    /// Records `camera` if a sample is due, and draws it.
    func record(_ camera: CameraPose) {
        if let sample = recorder?.record(camera) {
            overlay.append(sample)
        }
    }

    /// The camera jumped (a place, a restored view): the track starts a new
    /// segment rather than drawing a line across.
    func markJump() { recorder?.markJump() }

    /// Writes buffered samples out, for when the app may be suspended.
    func flush() { recorder?.flush() }

    // MARK: Drawing

    /// Draws the track being recorded, or else the latest one, as a tube.
    var showsTrack = false {
        didSet {
            overlay.isEnabled = showsTrack
            if showsTrack, overlay.path == nil, recorder == nil, let latestTrack {
                do {
                    overlay.path = try TrackPath(contentsOf: latestTrack)
                } catch {
                    print("[AlsoMaps] couldn't read track \(latestTrack.lastPathComponent): \(error)")
                }
            }
        }
    }

    // MARK: Playback

    /// Starts the latest track from the start and returns its first pose,
    /// or nil if there's nothing to play.
    func startPlayback() -> CameraPose? {
        guard playback == nil, recorder == nil, let latestTrack else { return nil }
        do {
            guard let track = try TrackPlayback(contentsOf: latestTrack) else {
                print("[AlsoMaps] track \(latestTrack.lastPathComponent) has no samples")
                return nil
            }
            playback = track
            playbackTime = 0
            playbackElapsed = 0
            playbackDuration = Int(track.duration.rounded(.up))
            print("[AlsoMaps] playing track \(latestTrack.lastPathComponent): \(track.samples.count) samples, \(String(format: "%.1f", track.duration)) s")
            return track.pose(at: 0)
        } catch {
            print("[AlsoMaps] couldn't read track \(latestTrack.lastPathComponent): \(error)")
            return nil
        }
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
