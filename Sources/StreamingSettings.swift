import Foundation

/// Runtime streaming knobs, adjustable from the Tuning window and saved
/// between launches. `default` is the hand-tuned baseline the app shipped
/// with; Reset goes back to it.
struct StreamingSettings: Codable, Equatable {
    /// SSE for tiles the LOD camera sees; lower = sharper and more tiles.
    var detail = 16.0
    /// SSE for tiles outside the LOD camera's view, which is most of an
    /// expanded region; lower = sharper far away.
    var outerDetail = 64.0
    /// Immersive only: how far past the volume-sized square to stream, as a
    /// multiple of its half-width. 1 = exactly what the volume shows.
    var immersiveRegion = 1.0
    /// Main-thread time per frame for turning loaded tiles into RealityKit
    /// entities; higher fills in faster but hitches more (see #1).
    var uploadBudgetMilliseconds = 6.0
    /// Concurrent tile requests.
    var simultaneousLoads = 20.0
    /// Loaded-tile cache budget.
    var cacheMegabytes = 512.0
    /// Keep parent tiles until all their children have loaded.
    var forbidHoles = false

    static let `default` = StreamingSettings()

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
