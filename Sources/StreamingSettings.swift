import Foundation

/// Runtime streaming and control knobs, adjustable from the Tuning window and
/// saved between launches. `default` is the hand-tuned baseline the app shipped
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

    enum TurnPivot: String, Codable, CaseIterable {
        /// Spin the map about its centre (the focus point).
        case center
        /// Turn about the middle of the map's near edge, where you are, so
        /// turning and moving forward feels like flying.
        case frontEdge
    }
    /// What keyboard (Q/E) and controller (right stick) turns pivot around.
    var keyboardTurnPivot = TurnPivot.center
    /// Largest view half-width zoom-out allows, kilometres.
    var zoomOutLimitKilometres = 20.0

    static let `default` = StreamingSettings()

    init() {}

    /// Missing keys keep their defaults, so adding a setting doesn't throw
    /// away everything saved by an older build.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamingSettings()
        detail = try c.decodeIfPresent(Double.self, forKey: .detail) ?? d.detail
        outerDetail = try c.decodeIfPresent(Double.self, forKey: .outerDetail) ?? d.outerDetail
        immersiveRegion = try c.decodeIfPresent(Double.self, forKey: .immersiveRegion) ?? d.immersiveRegion
        uploadBudgetMilliseconds = try c.decodeIfPresent(Double.self, forKey: .uploadBudgetMilliseconds) ?? d.uploadBudgetMilliseconds
        simultaneousLoads = try c.decodeIfPresent(Double.self, forKey: .simultaneousLoads) ?? d.simultaneousLoads
        cacheMegabytes = try c.decodeIfPresent(Double.self, forKey: .cacheMegabytes) ?? d.cacheMegabytes
        forbidHoles = try c.decodeIfPresent(Bool.self, forKey: .forbidHoles) ?? d.forbidHoles
        keyboardTurnPivot = try c.decodeIfPresent(TurnPivot.self, forKey: .keyboardTurnPivot) ?? d.keyboardTurnPivot
        zoomOutLimitKilometres = try c.decodeIfPresent(Double.self, forKey: .zoomOutLimitKilometres) ?? d.zoomOutLimitKilometres
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
