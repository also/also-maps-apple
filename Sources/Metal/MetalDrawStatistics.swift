import Foundation
import Metal

/// Counts draw submissions, not streaming selection or presented frames.
/// In stereo a tile/draw/triangle is counted once for each encoded eye.
struct MetalDrawStatistics {
    var tiles = 0
    var submittedTiles = 0
    var totalDrawCalls = 0
    var drawCalls = 0
    var totalTriangles = 0
    var triangles = 0

    mutating func add(_ other: MetalDrawStatistics) {
        tiles += other.tiles
        submittedTiles += other.submittedTiles
        totalDrawCalls += other.totalDrawCalls
        drawCalls += other.drawCalls
        totalTriangles += other.totalTriangles
        triangles += other.triangles
    }

    var summary: String {
        "tiles \(submittedTiles)/\(tiles), draws \(drawCalls)/\(totalDrawCalls), triangles \(triangles)/\(totalTriangles) submitted"
    }
}

/// GPU execution times of command buffers, summed on whichever thread Metal
/// calls the completion handler on, and read and reset once an interval.
final class MetalGPUTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var total = 0.0
    private var longest = 0.0

    func add(seconds: Double) {
        lock.lock()
        count += 1
        total += seconds
        longest = max(longest, seconds)
        lock.unlock()
    }

    /// The buffers completed since the last call, and resets.
    func take() -> (count: Int, mean: Double, max: Double) {
        lock.lock()
        defer { lock.unlock() }
        let result = (count, count > 0 ? total / Double(count) : 0, longest)
        count = 0
        total = 0
        longest = 0
        return result
    }
}

/// Opt-in, once-a-second submission counters, accumulated over the interval,
/// and the GPU time of the command buffers that finished in it.
/// The CPU encode interval is separately available as the MetalEncode signpost.
struct MetalDrawLog {
    private let enabled = ProcessInfo.processInfo.environment["ALSOMAPS_METAL_STATS"] == "1"
    private var lastPrint = Date()
    private var statistics = MetalDrawStatistics()
    private var frames = 0
    private let gpuTimes = MetalGPUTimes()

    /// Call before committing `commands`. Adds a completion handler that
    /// records how long the GPU spent on the buffer: gpuStartTime to
    /// gpuEndTime, or kernelStartTime to kernelEndTime where the GPU times
    /// aren't reported (they read 0). Not the time to presentation, so it
    /// doesn't include waiting for the next display refresh.
    func observe(_ commands: MTLCommandBuffer) {
        guard enabled else { return }
        let gpuTimes = gpuTimes
        commands.addCompletedHandler { buffer in
            var seconds = buffer.gpuEndTime - buffer.gpuStartTime
            if !(buffer.gpuStartTime > 0 && seconds > 0) {
                seconds = buffer.kernelEndTime - buffer.kernelStartTime
            }
            if seconds > 0, seconds.isFinite { gpuTimes.add(seconds: seconds) }
        }
    }

    mutating func record(_ frame: MetalDrawStatistics) {
        guard enabled else { return }
        statistics.add(frame)
        frames += 1
        let now = Date()
        guard now.timeIntervalSince(lastPrint) >= 1 else { return }
        let gpu = gpuTimes.take()
        let gpuSummary = gpu.count > 0
            ? String(format: "GPU %.2f ms mean, %.2f ms max over %ld buffers", gpu.mean * 1000, gpu.max * 1000, gpu.count)
            : "GPU time n/a"
        print("[AlsoMaps] Metal: \(frames) encoded frames, \(statistics.summary) (interval totals), \(gpuSummary)")
        statistics = MetalDrawStatistics()
        frames = 0
        lastPrint = now
    }
}
