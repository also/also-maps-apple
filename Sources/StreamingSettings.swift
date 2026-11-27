import Foundation

/// Runtime streaming and control knobs, adjustable in Settings and
/// saved between launches. `default` is the hand-tuned baseline the app shipped
/// with; Reset goes back to it.
struct StreamingSettings: Codable, Equatable {
    /// SSE for tiles the LOD camera sees; lower = sharper and more tiles.
    var detail = 16.0
    /// SSE for tiles outside the LOD camera's view, which is most of an
    /// expanded region; lower = sharper far away.
    var outerDetail = 64.0
    /// Immersive only: stream only `immersiveReach` around the viewer rather
    /// than everything visible, out to the horizon.
    var limitsImmersiveReach = false
    /// The limit, as a multiple of the camera's height above the ground (the
    /// same multiple of the eye's height above the base plane, in the room).
    var immersiveReach = 35.0
    /// Tiles whose RealityKit resources are built at once (off the main
    /// thread); higher fills in faster but uses more memory and CPU at once.
    var uploadConcurrency = 12.0
    /// Concurrent tile requests.
    var simultaneousLoads = 64.0
    /// Loaded-tile cache budget.
    var cacheMegabytes = 512.0
    /// Keep parent tiles until all their children are drawable.
    var forbidHoles = true

    /// Where the tiles come from.
    var tileSource = TileSource.googlePhotorealistic

    /// Speeds and stick response for the keyboard, game controller and
    /// on-screen sticks: only the ones changed from the defaults.
    var controls = ControlSettings()

    static let `default` = StreamingSettings()

    init() {}

    /// Missing keys keep their defaults, so adding a setting doesn't throw
    /// away everything saved by an older build.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamingSettings()
        detail = try c.decodeIfPresent(Double.self, forKey: .detail) ?? d.detail
        outerDetail = try c.decodeIfPresent(Double.self, forKey: .outerDetail) ?? d.outerDetail
        limitsImmersiveReach = try c.decodeIfPresent(Bool.self, forKey: .limitsImmersiveReach) ?? d.limitsImmersiveReach
        immersiveReach = try c.decodeIfPresent(Double.self, forKey: .immersiveReach) ?? d.immersiveReach
        uploadConcurrency = try c.decodeIfPresent(Double.self, forKey: .uploadConcurrency) ?? d.uploadConcurrency
        simultaneousLoads = try c.decodeIfPresent(Double.self, forKey: .simultaneousLoads) ?? d.simultaneousLoads
        cacheMegabytes = try c.decodeIfPresent(Double.self, forKey: .cacheMegabytes) ?? d.cacheMegabytes
        forbidHoles = try c.decodeIfPresent(Bool.self, forKey: .forbidHoles) ?? d.forbidHoles
        tileSource = (try? c.decodeIfPresent(TileSource.self, forKey: .tileSource)) ?? d.tileSource
        controls = (try? c.decodeIfPresent(ControlSettings.self, forKey: .controls)) ?? d.controls
    }

    private static let defaultsKey = "StreamingSettings"

    static func load() -> StreamingSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(StreamingSettings.self, from: data)
        else { return .default }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Preferences about what's shown, kept apart from `StreamingSettings` so
/// Reset to Defaults leaves them alone.
enum ViewPreferences {
    /// UserDefaults key: show tile and request stats over the map.
    static let showsStatsKey = "ShowsStats"
    /// UserDefaults key: draw tiles with the app's Metal renderer instead of
    /// RealityKit (the map window on a screen, the immersive mode on visionOS).
    static let drawsWithMetalKey = "DrawsWithMetal"
    /// UserDefaults key: show the wrench that opens the volume's debug panel.
    static let showsDebugControlsKey = "ShowsDebugControls"

    /// The setting, or ALSOMAPS_METAL=1, which turns it on for a run.
    static var drawsWithMetal: Bool {
        ProcessInfo.processInfo.environment["ALSOMAPS_METAL"] == "1"
            || UserDefaults.standard.bool(forKey: drawsWithMetalKey)
    }
}
