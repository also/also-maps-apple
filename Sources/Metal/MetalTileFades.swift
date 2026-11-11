import Foundation
import simd

/// Per-view fade state for MetalTileRenderer: how far each drawn tile has
/// faded in, and the tiles that streaming stopped drawing, kept for the fade
/// so they dissolve out instead of vanishing. Refinement (a parent replaced
/// by its children in one frame) becomes a cross-fade: the children dissolve
/// in through the same screen-space pattern the parent dissolves out of, so
/// each pixel shows exactly one of them and there's no blending, sorting or
/// z-fighting.
///
/// Only appearance and disappearance need fading: a tile's texture is built
/// with its geometry, before cesium-native counts it as loaded, so a tile
/// never shows untextured first.
///
/// One per host (a window, the immersive space): `update` once a frame with
/// what streaming drew, then pass it to every `encode` of that frame. Used
/// on the main thread, as the hosts draw there.
final class MetalTileFades {
    /// Seconds a tile takes to fade fully in or out: `defaultDuration`, or
    /// `ALSOMAPS_METAL_FADE=<seconds>`; `ALSOMAPS_METAL_FADE=0` turns fades
    /// off, for comparison. A long one makes the fades easy to see.
    static let duration: TimeInterval = {
        guard let value = ProcessInfo.processInfo.environment["ALSOMAPS_METAL_FADE"].flatMap(Double.init),
              value >= 0 else { return defaultDuration }
        return value
    }()
    static let defaultDuration: TimeInterval = 0.35
    static var isEnabled: Bool { duration > 0 }

    /// A tile streaming no longer draws, still fading out. Its placement is
    /// carried along with the anchor frame, which can move every frame.
    struct Leaving {
        let tile: CNTileMesh
        var placement: simd_float4x4
        var visibility: Float
    }

    /// Tiles fading out, by identifier.
    private(set) var leaving: [UInt64: Leaving] = [:]
    private var lastTime: TimeInterval?

    func update(drawn: [(tile: CNTileMesh, placement: simd_float4x4)], now: TimeInterval) {
        guard Self.isEnabled else { return }
        // A long gap (paused) shouldn't jump fades forward, nor a clock
        // running backwards reverse them.
        let step = Float(min(max(now - (lastTime ?? now), 0), 0.1) / Self.duration)
        lastTime = now

        let drawnIDs = Set(drawn.map { $0.tile.identifier })
        let gone = current.filter { !drawnIDs.contains($0.key) }

        var next: [UInt64: Drawn] = [:]
        next.reserveCapacity(drawn.count)
        for (tile, placement) in drawn {
            let id = tile.identifier
            if let old = current[id] {
                next[id] = Drawn(tile: tile, placement: placement, visibility: min(old.visibility + step, 1),
                                 replaces: old.replaces)
            } else {
                // New, so it starts at 0: on the first frame the map fades in
                // from the sky. A tile coming back mid-fade-out resumes from
                // there. Appearing as others leave, it's (most likely) their
                // refinement or coarsening, so it replaces them.
                let previous = leaving.removeValue(forKey: id)?.visibility ?? 0
                next[id] = Drawn(tile: tile, placement: placement, visibility: min(previous + step, 1),
                                 replaces: !gone.isEmpty)
            }
        }

        // Tiles drawn last frame and not now start leaving. One that
        // replaced others leaves fully shown even if it was still fading
        // in, since what it replaced covered the rest: then it's always the
        // exact complement of whatever replaces it in turn, and fast,
        // chained refinement (parent, child, grandchild inside one fade)
        // never shows the sky through. One that was fading in from nothing
        // leaves from where it had got to.
        if !leaving.isEmpty || !gone.isEmpty {
            let motion = anchorMotion(to: next)
            for id in leaving.keys {
                leaving[id]!.placement = motion * leaving[id]!.placement
                leaving[id]!.visibility -= step
            }
            for (id, old) in gone {
                let start: Float = old.replaces ? 1 : old.visibility
                leaving[id] = Leaving(tile: old.tile, placement: motion * old.placement, visibility: start - step)
            }
            leaving = leaving.filter { $0.value.visibility > 0 }
        }
        current = next
    }

    /// 0 (not shown) to 1 (fully in), for a tile drawn this frame.
    func visibility(of tile: CNTileMesh) -> Float {
        Self.isEnabled ? current[tile.identifier]?.visibility ?? 1 : 1
    }

    private struct Drawn {
        let tile: CNTileMesh
        let placement: simd_float4x4
        let visibility: Float
        /// Appeared as other tiles left (MetalTileFades.update).
        let replaces: Bool
    }
    private var current: [UInt64: Drawn] = [:]

    /// How the anchor frame moved since last frame, from a tile drawn in
    /// both: every placement is the same anchor-from-ECEF transform times a
    /// translation to the tile's centre, so one tile's change is everyone's.
    /// The tile nearest the anchor keeps the float error smallest.
    private func anchorMotion(to next: [UInt64: Drawn]) -> simd_float4x4 {
        var best: (now: simd_float4x4, then: simd_float4x4, distance: Float)?
        for (id, tile) in next {
            guard let then = current[id]?.placement else { continue }
            let now = tile.placement
            let distance = simd_length_squared(SIMD3(now.columns.3.x, now.columns.3.y, now.columns.3.z))
            if best == nil || distance < best!.distance { best = (now, then, distance) }
        }
        guard let best, best.now != best.then else { return matrix_identity_float4x4 }
        return best.now * best.then.inverse
    }
}
