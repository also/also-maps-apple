import AVFoundation
import Observation

/// Loops `soundtrack.mp3` while the app is active, if the build bundled one.
/// The track lives in the gitignored Local/ folder and is copied in only when
/// present, so builds from a clean checkout simply have no soundtrack.
@MainActor
@Observable
final class Soundtrack {
    private static let mutedKey = "SoundtrackMuted"

    private let player: AVAudioPlayer?
    private var isActive = false

    /// Whether a soundtrack was bundled; the mute button only shows if so.
    var isAvailable: Bool { player != nil }

    var isMuted = UserDefaults.standard.bool(forKey: mutedKey) {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: Self.mutedKey)
            update()
        }
    }

    init() {
        guard let url = Bundle.main.url(forResource: "soundtrack", withExtension: "mp3") else {
            player = nil
            return
        }
        // Ambient: mixes with other apps' audio and respects the silent switch.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 0.5
        player?.prepareToPlay()
        self.player = player
    }

    /// Call as the app becomes active or inactive.
    func setActive(_ active: Bool) {
        isActive = active
        update()
    }

    private func update() {
        guard let player else { return }
        if isActive && !isMuted {
            if !player.isPlaying { player.play() }
        } else if player.isPlaying {
            player.pause()
        }
    }
}
