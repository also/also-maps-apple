import Foundation
import simd

/// The sun's view for a shadow map: an orthographic projection along the
/// sun's direction, in the anchor frame (x east, y up, z south, metres),
/// covering a disc of ground around a centre and deep enough to hold every
/// caster. Pure maths, for MetalTileRenderer's shadow pass.
struct SunShadowFit: Equatable {
    /// Anchor frame → the shadow map's clip space: x and y in −1...1 across
    /// the covered disc's square, z in 0...1 from the caster nearest the
    /// sun to the farthest (regular Z, unlike the main pass), w = 1.
    var clipFromAnchor: simd_float4x4
    /// Metres of ground (across the sun's view) per shadow-map texel.
    var texelSize: Double

    /// Nil if the sun direction isn't usable or there's nothing to cast.
    ///
    /// The square's size depends only on `radius` and its centre snaps to
    /// whole texels in the sun's view, so while the sun and radius hold
    /// still, panning moves the map by whole texels and shadow edges don't
    /// shimmer. Depth spans every caster point, padded, even ones outside
    /// the square, so a tall building just outside still casts in.
    init?(sunDirection: SIMD3<Double>, casters: [SIMD3<Double>], centre: SIMD3<Double>, radius: Double,
          resolution: Int) {
        let length = simd_length(sunDirection)
        guard length > 0, length.isFinite, radius > 0, radius.isFinite, resolution > 0, !casters.isEmpty
        else { return nil }
        let toSun = sunDirection / length
        // Any up perpendicular to the sun will do; north when the sun is
        // near the zenith, where the anchor's up is nearly parallel.
        let reference: SIMD3<Double> = abs(toSun.y) > 0.99 ? [0, 0, -1] : [0, 1, 0]
        let right = simd_normalize(simd_cross(reference, toSun))
        let up = simd_cross(toSun, right)

        var nearest = -Double.infinity, farthest = Double.infinity
        for point in casters {
            let along = simd_dot(point, toSun)
            guard along.isFinite else { continue }
            nearest = max(nearest, along)
            farthest = min(farthest, along)
        }
        guard nearest.isFinite, farthest.isFinite else { return nil }
        // A little room either side, so the nearest and farthest surfaces
        // don't sit on the clip planes.
        let padding = max(1, (nearest - farthest) * 0.01)
        nearest += padding
        farthest -= padding
        let depth = nearest - farthest

        let texel = 2 * radius / Double(resolution)
        let centreX = (simd_dot(centre, right) / texel).rounded() * texel
        let centreY = (simd_dot(centre, up) / texel).rounded() * texel

        // Rows: x = (right · p − cx) / r, y = (up · p − cy) / r,
        // z = (nearest − toSun · p) / depth, w = 1.
        let rows = simd_double4x4(rows: [
            SIMD4(right / radius, -centreX / radius),
            SIMD4(up / radius, -centreY / radius),
            SIMD4(-toSun / depth, nearest / depth),
            SIMD4(0, 0, 0, 1),
        ])
        clipFromAnchor = simd_float4x4(columns: (SIMD4<Float>(rows.columns.0), SIMD4<Float>(rows.columns.1),
                                              SIMD4<Float>(rows.columns.2), SIMD4<Float>(rows.columns.3)))
        texelSize = texel
    }

    /// The eight corners of a box, for `casters`.
    static func corners(minimum: SIMD3<Double>, maximum: SIMD3<Double>) -> [SIMD3<Double>] {
        (0..<8).map { i in
            SIMD3(i & 1 == 0 ? minimum.x : maximum.x,
                  i & 2 == 0 ? minimum.y : maximum.y,
                  i & 4 == 0 ? minimum.z : maximum.z)
        }
    }
}
