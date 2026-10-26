import Foundation
import simd
import Testing

private let degrees = Double.pi / 180

/// A pose's forward ray.
private func ray(_ camera: CameraPose) -> Ray {
    Ray(origin: camera.position, direction: camera.basis.forward)
}

private func isFinite(_ v: SIMD3<Double>) -> Bool {
    v.x.isFinite && v.y.isFinite && v.z.isFinite
}

struct GeodesyTests {
    @Test(arguments: [
        (37.7955, -122.3937, -32.0),
        (0.0, 0.0, 0.0),
        (-33.9, 151.2, 9_000.0),
        (89.9999, 45.0, 1_000.0),
        (-89.9, -170.0, -400.0),
        (51.5, -0.1, 2_000_000.0),
    ])
    func geodeticRoundTrip(latitude: Double, longitude: Double, height: Double) {
        let point = Geodesy.ecef(latitude: latitude, longitude: longitude, height: height)
        let (coordinate, roundTrip) = Geodesy.geodetic(point)
        #expect(abs(coordinate.latitude - latitude) < 1e-9)
        #expect(abs(GeoMath.normalizedLongitude(coordinate.longitude - longitude)) < 1e-9)
        #expect(abs(roundTrip - height) < 1e-6)
    }

    @Test func anchorFrameIsOrthonormalEastUpSouth() {
        let rotation = Geodesy.anchorFrameRotation(latitude: 37.8, longitude: -122.4)
        let product = rotation.transpose * rotation
        for i in 0..<3 {
            for j in 0..<3 {
                #expect(abs(product[i][j] - (i == j ? 1 : 0)) < 1e-12)
            }
        }
        let frame = Geodesy.enu(latitude: 37.8, longitude: -122.4)
        #expect(simd_distance(rotation.columns.0, frame.east) < 1e-12)
        #expect(simd_distance(rotation.columns.1, frame.up) < 1e-12)
        #expect(simd_distance(rotation.columns.2, -frame.north) < 1e-12)
    }

    @Test func straightDownHitsAtTheRequestedHeight() {
        let camera = CameraPose(latitude: 37.8, longitude: -122.4, height: 1_000, heading: 0, pitch: -.pi / 2)
        guard case let .hit(point, t) = Geodesy.intersect(ray: ray(camera), surfaceHeight: 50) else {
            Issue.record("expected a hit"); return
        }
        #expect(abs(Geodesy.geodetic(point).height - 50) < 1e-3)
        #expect(abs(t - 950) < 1e-3)
    }

    @Test(arguments: [0.0, 1_000.0, 9_000.0, -500.0])
    func obliqueHitIsRefinedToTheHeight(height: Double) {
        let camera = CameraPose(latitude: 10, longitude: 20, height: height + 20_000, heading: 1, pitch: -30 * degrees)
        guard case let .hit(point, t) = Geodesy.intersect(ray: ray(camera), surfaceHeight: height) else {
            Issue.record("expected a hit"); return
        }
        #expect(t >= 0)
        #expect(abs(Geodesy.geodetic(point).height - height) < 1e-3)
    }

    /// Horizon dip at 24 km is about 5°: −4° misses, −6° hits.
    @Test func shallowRaysMissBeyondTheHorizon() {
        let shallow = CameraPose(latitude: 0, longitude: 0, height: 24_000, heading: 0, pitch: -4 * degrees)
        let steeper = CameraPose(latitude: 0, longitude: 0, height: 24_000, heading: 0, pitch: -6 * degrees)
        #expect(Geodesy.intersect(ray: ray(shallow), surfaceHeight: 0) == .miss)
        guard case .hit = Geodesy.intersect(ray: ray(steeper), surfaceHeight: 0) else {
            Issue.record("expected a hit"); return
        }
    }

    @Test func lookingUpMisses() {
        let camera = CameraPose(latitude: 0, longitude: 0, height: 100, heading: 0, pitch: 10 * degrees)
        #expect(Geodesy.intersect(ray: ray(camera), surfaceHeight: 0) == .miss)
    }

    /// Around the tangent ray the answer is a hit or a miss, never NaN, and
    /// a hit stays finite and forward.
    @Test(arguments: [24_000.0, 410_000.0, 2_600_000.0])
    func grazingRaysAreTotal(height: Double) {
        let latitude = 0.0
        let dip = acos(Geodesy.semiMajorAxis / (Geodesy.semiMajorAxis + height))
        for offset in [-1e-3, -1e-6, 0, 1e-6, 1e-3] {
            let camera = CameraPose(latitude: latitude, longitude: 0, height: height, heading: .pi / 2,
                                    pitch: -dip + offset)
            switch Geodesy.intersect(ray: ray(camera), surfaceHeight: 0) {
            case let .hit(point, t):
                #expect(isFinite(point))
                #expect(t >= 0 && t.isFinite)
            case .miss:
                break
            case .invalidRay:
                Issue.record("a valid ray was rejected")
            }
        }
    }

    @Test func cameraBelowTheSurfaceGetsTheForwardExit() {
        let camera = CameraPose(latitude: 0, longitude: 0, height: 100, heading: 0, pitch: -10 * degrees)
        guard case let .hit(point, t) = Geodesy.intersect(ray: ray(camera), surfaceHeight: 500) else {
            Issue.record("expected the forward exit"); return
        }
        #expect(t >= 0)
        #expect(isFinite(point))
    }

    @Test func malformedRaysAreRejected() {
        let origin = Geodesy.ecef(latitude: 0, longitude: 0, height: 100)
        #expect(Geodesy.intersect(ray: Ray(origin: origin, direction: .zero), surfaceHeight: 0) == .invalidRay)
        #expect(Geodesy.intersect(ray: Ray(origin: SIMD3(.nan, 0, 0), direction: SIMD3(1, 0, 0)),
                                  surfaceHeight: 0) == .invalidRay)
        #expect(Geodesy.intersect(ray: Ray(origin: origin, direction: SIMD3(0, 0, .infinity)),
                                  surfaceHeight: 0) == .invalidRay)
    }
}

struct CameraPoseTests {
    @Test func basisIsOrthonormalWithLevelRight() {
        let camera = CameraPose(latitude: 37.8, longitude: -122.4, height: 500, heading: 1.2, pitch: -0.6)
        let (forward, right, up) = camera.basis
        #expect(abs(simd_length(forward) - 1) < 1e-12)
        #expect(abs(simd_length(right) - 1) < 1e-12)
        #expect(abs(simd_dot(forward, right)) < 1e-12)
        #expect(abs(simd_dot(up, forward)) < 1e-12)
        let localUp = Geodesy.enu(latitude: 37.8, longitude: -122.4).up
        #expect(abs(simd_dot(right, localUp)) < 1e-12)
        #expect(simd_dot(up, localUp) > 0)
    }

    @Test func poseFromPositionAndForwardRoundTrips() {
        let camera = CameraPose(latitude: -12, longitude: 130, height: 3_000, heading: -2.5, pitch: -0.3)
        let rebuilt = CameraPose(position: camera.position, forward: camera.basis.forward)
        #expect(abs(rebuilt.latitude - camera.latitude) < 1e-9)
        #expect(abs(rebuilt.longitude - camera.longitude) < 1e-9)
        #expect(abs(rebuilt.height - camera.height) < 1e-6)
        #expect(abs(remainder(rebuilt.heading - camera.heading, 2 * .pi)) < 1e-9)
        #expect(abs(rebuilt.pitch - camera.pitch) < 1e-9)
    }
}

struct SimilarityTests {
    @Test func inverseAndComposition() {
        let a = Similarity(scale: 2.5, rotation: simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 3))),
                           translation: SIMD3(1, -2, 3))
        let b = Similarity(scale: 0.1, rotation: simd_quatd(angle: -1.1, axis: SIMD3(0, 1, 0)),
                           translation: SIMD3(-4, 5, 6))
        let x = SIMD3(0.3, -7.0, 11.0)
        #expect(simd_distance(a.inverse.apply(a.apply(x)), x) < 1e-12)
        #expect(simd_distance(a.after(b).apply(x), a.apply(b.apply(x))) < 1e-12)
    }
}
