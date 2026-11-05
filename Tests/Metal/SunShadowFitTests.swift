import Foundation
import simd
import Testing

struct SunShadowFitTests {
    private func project(_ fit: SunShadowFit, _ point: SIMD3<Double>) -> SIMD3<Float> {
        let clip = fit.clipFromAnchor * SIMD4<Float>(SIMD3<Float>(point), 1)
        return SIMD3(clip.x, clip.y, clip.z) / clip.w
    }

    /// A 100 m box of buildings around the anchor.
    private let city = SunShadowFit.corners(minimum: [-100, 0, -100], maximum: [100, 60, 100])

    @Test
    func coversTheDiscAndEveryCasterInDepth() throws {
        let sun = simd_normalize(SIMD3<Double>(1, 1, 0.3))
        let fit = try #require(SunShadowFit(sunDirection: sun, casters: city, centre: .zero, radius: 200,
                                            resolution: 1000))
        let centre = project(fit, .zero)
        #expect(abs(centre.x) < 0.01 && abs(centre.y) < 0.01)
        for corner in city {
            let p = project(fit, corner)
            #expect(p.z > 0 && p.z < 1)
            #expect(abs(p.x) <= 1 && abs(p.y) <= 1)
        }
        #expect(abs(fit.texelSize - 0.4) < 1e-12)
    }

    /// Nearer the sun is nearer 0, and two points on one sun ray land on the
    /// same texel: the one nearer the sun shadows the other.
    @Test
    func pointsOnOneSunRayShareATexelAndOrderByDepth() throws {
        let sun = simd_normalize(SIMD3<Double>(-0.4, 0.8, 0.45))
        let fit = try #require(SunShadowFit(sunDirection: sun, casters: city, centre: .zero, radius: 200,
                                            resolution: 1000))
        let ground = SIMD3<Double>(10, 0, -20)
        let roof = ground + sun * 50
        let a = project(fit, ground), b = project(fit, roof)
        #expect(simd_distance(SIMD2(a.x, a.y), SIMD2(b.x, b.y)) < 1e-4)
        #expect(b.z < a.z)
    }

    @Test
    func handlesTheSunAtTheZenith() throws {
        let fit = try #require(SunShadowFit(sunDirection: [0, 1, 0], casters: city, centre: .zero, radius: 200,
                                            resolution: 1000))
        // Straight down: the roof is nearer the sun than the ground below it.
        #expect(project(fit, [0, 60, 0]).z < project(fit, [0, 0, 0]).z)
        #expect(project(fit, [0, 60, 0]).x.isFinite)
    }

    /// Small moves of the centre move the map by whole texels or not at all.
    @Test
    func snapsTheCentreToWholeTexels() throws {
        let sun = simd_normalize(SIMD3<Double>(0.2, 0.7, 0.6))
        let a = try #require(SunShadowFit(sunDirection: sun, casters: city, centre: [0, 0, 0], radius: 200,
                                          resolution: 1000))
        let b = try #require(SunShadowFit(sunDirection: sun, casters: city, centre: [0.05, 0, 0.05], radius: 200,
                                          resolution: 1000))
        #expect(a.clipFromAnchor == b.clipFromAnchor)
        let far = try #require(SunShadowFit(sunDirection: sun, casters: city, centre: [3, 0, 0], radius: 200,
                                            resolution: 1000))
        // The shift in texels (2 / resolution of clip space each) is whole.
        let shift = (far.clipFromAnchor.columns.3.x - a.clipFromAnchor.columns.3.x) / (2 / 1000)
        #expect(abs(shift - shift.rounded()) < 1e-3)
    }

    @Test
    func refusesUnusableInput() {
        #expect(SunShadowFit(sunDirection: .zero, casters: city, centre: .zero, radius: 200, resolution: 1000) == nil)
        #expect(SunShadowFit(sunDirection: [0, 1, 0], casters: [], centre: .zero, radius: 200, resolution: 1000) == nil)
        #expect(SunShadowFit(sunDirection: [0, 1, 0], casters: city, centre: .zero, radius: 0, resolution: 1000) == nil)
    }
}
