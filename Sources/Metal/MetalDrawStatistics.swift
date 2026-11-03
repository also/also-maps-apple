import Foundation

/// Counts draw submissions, not streaming selection or presented frames.
/// In stereo a tile/draw/triangle is counted once for each encoded eye.
struct MetalDrawStatistics {
    var tiles = 0
    var drawnTiles = 0
    var totalDrawCalls = 0
    var drawCalls = 0
    var totalTriangles = 0
    var triangles = 0

    mutating func add(_ other: MetalDrawStatistics) {
        tiles += other.tiles
        drawnTiles += other.drawnTiles
        totalDrawCalls += other.totalDrawCalls
        drawCalls += other.drawCalls
        totalTriangles += other.totalTriangles
        triangles += other.triangles
    }

    var summary: String {
        "tiles \(drawnTiles)/\(tiles), draws \(drawCalls)/\(totalDrawCalls), triangles \(triangles)/\(totalTriangles) submitted"
    }
}

/// Opt-in, once-a-second submission counters, accumulated over the interval.
/// The CPU encode interval is separately available as the MetalEncode signpost.
struct MetalDrawLog {
    private let enabled = ProcessInfo.processInfo.environment["ALSOMAPS_METAL_STATS"] == "1"
    private var lastPrint = Date()
    private var statistics = MetalDrawStatistics()
    private var frames = 0

    mutating func record(_ frame: MetalDrawStatistics) {
        guard enabled else { return }
        statistics.add(frame)
        frames += 1
        let now = Date()
        guard now.timeIntervalSince(lastPrint) >= 1 else { return }
        print("[AlsoMaps] Metal: \(frames) encoded frames, \(statistics.summary) (interval totals)")
        statistics = MetalDrawStatistics()
        frames = 0
        lastPrint = now
    }
}
