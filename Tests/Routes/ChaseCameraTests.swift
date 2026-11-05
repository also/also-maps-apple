import Foundation
import Testing

private let degrees = Double.pi / 180
private let point = GeoCoordinate(latitude: 37.8, longitude: -122.4)

struct ChaseCameraTests {
    @Test func sitsBehindAndAboveLookingAtThePoint() {
        var chase = ChaseCamera(distance: 100, height: 40)
        let pose = chase.pose(following: point, height: 10, travelHeading: 90 * degrees, deltaTime: 1 / 90)
        // Travelling east: the camera is to the west, facing east and down.
        // Within the meridians' convergence over 100 m.
        #expect(abs(pose.heading - 90 * degrees) < 1e-4)
        #expect(pose.longitude < point.longitude)
        #expect(abs(GeoMath.distance(from: pose.coordinate, to: point) - 100) < 0.1)
        #expect(abs(pose.height - 50) < 0.01)
        // GeoMath's sphere is a little smaller than the ellipsoid there.
        #expect(abs(pose.pitch - -atan2(40, 100)) < 3e-3)
    }

    @Test func turnsTowardANewHeadingGradually() {
        var chase = ChaseCamera(distance: 100, height: 40)
        _ = chase.pose(following: point, height: 0, travelHeading: 0, deltaTime: 0)
        // A sharp turn to the east: after one half-life, halfway.
        let pose = chase.pose(following: point, height: 0, travelHeading: 90 * degrees,
                              deltaTime: chase.headingHalfLife)
        #expect(abs(pose.heading - 45 * degrees) < 1e-3)
    }

    @Test func turnsTheShorterWayAcrossNorth() {
        var chase = ChaseCamera(distance: 100, height: 40)
        _ = chase.pose(following: point, height: 0, travelHeading: 350 * degrees, deltaTime: 0)
        _ = chase.pose(following: point, height: 0, travelHeading: 10 * degrees, deltaTime: chase.headingHalfLife)
        #expect(abs(remainder(chase.heading! - 0, 2 * .pi)) < 1e-6)
    }

    @Test func noTravelHeadingKeepsTheLastOne() {
        var chase = ChaseCamera(distance: 100, height: 40)
        _ = chase.pose(following: point, height: 0, travelHeading: 30 * degrees, deltaTime: 0)
        _ = chase.pose(following: point, height: 0, travelHeading: nil, deltaTime: 5)
        #expect(abs(chase.heading! - 30 * degrees) < 1e-9)
    }

    @Test func aHeadingThatDoesntTurnStaysPut() {
        var chase = ChaseCamera(distance: 100, height: 40)
        chase.turnsWithTravel = false
        _ = chase.pose(following: point, height: 0, travelHeading: 30 * degrees, deltaTime: 0)
        _ = chase.pose(following: point, height: 0, travelHeading: 120 * degrees, deltaTime: 5)
        #expect(abs(chase.heading! - 30 * degrees) < 1e-9)
    }

    @Test func heightEasesSoNoiseDoesntBob() {
        var chase = ChaseCamera(distance: 100, height: 40)
        _ = chase.pose(following: point, height: 0, travelHeading: 0, deltaTime: 0)
        let pose = chase.pose(following: point, height: 10, travelHeading: 0, deltaTime: chase.heightHalfLife)
        #expect(abs(pose.height - 45) < 0.01)
    }

    @Test func distanceFollowsTheRoutesSpeedWithinLimits() {
        #expect(ChaseCamera(typicalSpeed: 3).distance == 60)
        #expect(ChaseCamera(typicalSpeed: 7).distance == 140)
        #expect(ChaseCamera(typicalSpeed: 250).distance == 3_000)
    }
}
