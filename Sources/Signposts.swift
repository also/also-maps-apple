import OSLog

/// Signposts for timing the tile pipeline in Instruments or `xctrace`. The
/// Objective-C++ bridge logs to the same subsystem and categories
/// (CNTileStreamer.mm); see docs/profiling.md.
enum Signposts {
    static let subsystem = "com.ryanberdeen.MapVolume"
    /// Per-tile work: fetch, flatten, queue wait, mesh, textures.
    static let tiles = OSSignposter(subsystem: subsystem, category: "Tiles")
    /// Per-frame work on the main thread.
    static let frame = OSSignposter(subsystem: subsystem, category: "Frame")
}
