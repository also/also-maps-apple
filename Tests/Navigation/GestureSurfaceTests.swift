import Foundation
import simd
import Testing

struct GestureSurfaceTests {
    private static let sanFrancisco = GeoCoordinate(latitude: 37.7955, longitude: -122.3937)

    @Test(arguments: [1e-5, 0.01, 0.5, Double.pi / 2])
    func pointsLieOnTheGround(angularRadius: Double) {
        let surface = GestureSurface(center: Self.sanFrancisco, height: -32, angularRadius: angularRadius)
        let points = surface.ecefPoints()
        #expect(points.count == 1 + GestureSurface.rings * GestureSurface.bearings)
        for point in points {
            #expect(abs(Geodesy.geodetic(point).height - -32) < 1e-3)
        }
        // The rim is the requested arc from the center.
        let rim = Geodesy.geodetic(points.last!).coordinate
        let arc = GeoMath.distance(from: Self.sanFrancisco, to: rim) / GeoMath.earthRadius
        #expect(abs(arc - angularRadius) < 1e-6 * max(angularRadius, 1e-3))
    }

    /// In the center's frame the cap curves down from the origin and fits in
    /// a unit-sized box at any size. Its triangles use every point, cover
    /// each ring all the way round, and face up, toward a viewer above.
    @Test(arguments: [1e-5, 0.01, 0.5, Double.pi / 2])
    func localMeshIsUnitSizedAndFacesUp(angularRadius: Double) {
        let surface = GestureSurface(center: Self.sanFrancisco, height: 50, angularRadius: angularRadius)
        let (positions, faces) = surface.localMesh()
        #expect(positions.count == surface.ecefPoints().count)
        #expect(positions.first == SIMD3<Float>(0, 0, 0))
        for point in positions {
            #expect(point.y <= 1e-6)
            #expect(simd_length(point) < 1.6)
        }
        let rings = GestureSurface.rings, bearings = GestureSurface.bearings
        #expect(faces.count == 3 * (bearings + 2 * bearings * (rings - 1)))
        #expect(Set(faces) == Set((0..<positions.count).map(UInt16.init)))
        for t in stride(from: 0, to: faces.count, by: 3) {
            let a = SIMD3<Double>(positions[Int(faces[t])])
            let b = SIMD3<Double>(positions[Int(faces[t + 1])])
            let c = SIMD3<Double>(positions[Int(faces[t + 2])])
            // Up in the center's frame, and away from the globe's center at
            // the triangle, which the hemisphere's rim tilts far from up.
            #expect(simd_cross(b - a, c - a).y > 0)
            let earthCenter = SIMD3<Double>(0, -GeoMath.earthRadius / surface.unit, 0)
            #expect(simd_dot(simd_cross(b - a, c - a), (a + b + c) / 3 - earthCenter) > 0)
        }
    }

    @Test func horizonAngle() {
        #expect(GestureSurface.horizonAngle(cameraHeight: 10, groundHeight: 10) == 0)
        #expect(GestureSurface.horizonAngle(cameraHeight: 0, groundHeight: 10) == 0)
        let r = GeoMath.earthRadius
        let angle = GestureSurface.horizonAngle(cameraHeight: 1_000_000, groundHeight: 0)
        #expect(abs(angle - acos(r / (r + 1_000_000))) < 1e-12)
    }

    @Test func desiredIsClampedToAHemisphere() {
        let surface = GestureSurface.desired(center: Self.sanFrancisco, height: 0, reach: 3)
        #expect(surface.angularRadius == GestureSurface.maximumAngularRadius)
        #expect(GestureSurface.built(for: surface).angularRadius == GestureSurface.maximumAngularRadius)
    }

    @Test func rebuildsOnlyWhenNeeded() {
        let desired = GestureSurface.desired(center: Self.sanFrancisco, height: 0, reach: 0.01)
        let built = GestureSurface.built(for: desired)
        #expect(!built.needsRebuild(for: desired))

        // A small pan, zoom or change in ground is still covered.
        var moved = desired
        moved.center = GeoMath.destination(from: Self.sanFrancisco, bearing: 1, distance: 0.05 * 0.01 * GeoMath.earthRadius)
        #expect(!built.needsRebuild(for: moved))
        var zoomed = desired
        zoomed.angularRadius *= 0.9
        #expect(!built.needsRebuild(for: zoomed))
        var raised = desired
        raised.height += 10
        #expect(!built.needsRebuild(for: raised))

        moved.center = GeoMath.destination(from: Self.sanFrancisco, bearing: 1, distance: 0.2 * 0.01 * GeoMath.earthRadius)
        #expect(built.needsRebuild(for: moved))
        zoomed.angularRadius = desired.angularRadius * 1.3
        #expect(built.needsRebuild(for: zoomed))
        zoomed.angularRadius = desired.angularRadius * 0.5
        #expect(built.needsRebuild(for: zoomed))
        raised.height += 1_000
        #expect(built.needsRebuild(for: raised))
    }

    /// A hit on the mesh, between its points, lands on the ground at about
    /// the same place.
    @Test func snapPutsAHitOnTheGround() {
        let surface = GestureSurface(center: Self.sanFrancisco, height: 120, angularRadius: 0.2)
        let points = surface.ecefPoints()
        let chordMidpoint = (points[1] + points[2]) / 2
        let snapped = GestureSurface.snap(chordMidpoint, toHeight: 120)
        #expect(abs(Geodesy.geodetic(snapped).height - 120) < 1e-3)
        let along = simd_distance(points[1], points[2])
        #expect(simd_distance(snapped, chordMidpoint) < 0.01 * along)
    }
}
