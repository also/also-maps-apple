import Foundation
import Testing

private let degrees = Double.pi / 180

struct CommandMotionTests {
    private let state = NavigationState(camera: CameraPose(latitude: 37.8, longitude: -122.4, height: 500,
                                                           heading: 30 * degrees, pitch: -20 * degrees))
    private let context = NavigationContext(cameraGround: 0, minimumAltitude: 2, maximumAltitude: 11_000_000)

    private func run(_ motion: CommandMotion, frames: Int = 90) -> NavigationState {
        var motion = motion
        var state = state
        for _ in 0..<frames { state = motion.step(state, deltaTime: 1.0 / 60, context: context) }
        #expect(motion.isFinished)
        return state
    }

    @Test
    func aClimbChangesHeightOnlyByExactlyTheAmount() throws {
        let motion = try #require(CommandMotion(.climb(meters: 304.8), camera: state.camera, altitude: 500))
        let end = run(motion)
        #expect(abs(end.camera.height - 804.8) < 1e-6)
        #expect(end.camera.latitude == state.camera.latitude)
        #expect(end.camera.longitude == state.camera.longitude)
        #expect(end.camera.heading == state.camera.heading)
    }

    @Test
    func settingAltitudeClimbsByTheDifference() throws {
        let motion = try #require(CommandMotion(.setAltitude(meters: 200), camera: state.camera, altitude: 450))
        #expect(motion.climb == -250)
    }

    @Test
    func facingTurnsTheShortWay() throws {
        // From 30° to 300° is 90° left, not 270° right.
        let motion = try #require(CommandMotion(.face(headingDegrees: 300), camera: state.camera, altitude: 500))
        #expect(abs(motion.turn + 90 * degrees) < 1e-9)
        let end = run(motion)
        #expect(abs(NavigationOperations.wrapped(end.camera.heading - 300 * degrees)) < 1e-9)
    }

    @Test
    func aMoveTravelsItsDistance() throws {
        let motion = try #require(CommandMotion(.move(forwardMeters: 1_000, rightMeters: 0),
                                                camera: state.camera, altitude: 500))
        let end = run(motion)
        let travelled = GeoMath.distance(from: state.camera.coordinate, to: end.camera.coordinate)
        #expect(abs(travelled - 1_000) < 1)
        #expect(abs(end.camera.height - state.camera.height) < 1e-6)
    }

    @Test
    func aMotionEasesInRatherThanJumping() throws {
        var motion = try #require(CommandMotion(.climb(meters: 1_000), camera: state.camera, altitude: 500))
        let first = motion.step(state, deltaTime: 1.0 / 60, context: context)
        #expect(first.camera.height - state.camera.height < 1)
    }

    @Test
    func goToIsNotAMotion() {
        #expect(CommandMotion(.goTo(destination: .named(name: "Boston")), camera: state.camera, altitude: 500) == nil)
    }
}

struct MapCommandCodingTests {
    /// The JSON an external controller sends: Swift's synthesized enum
    /// coding, documented in docs/commands.md.
    @Test
    func commandsRoundTripAsDocumentedJSON() throws {
        let json = #"{"climb":{"meters":60.96}}"#
        let command = try JSONDecoder().decode(MapCommand.self, from: Data(json.utf8))
        #expect(command == .climb(meters: 60.96))

        let goTo = #"{"goTo":{"destination":{"named":{"name":"Ronda"}}}}"#
        #expect(try JSONDecoder().decode(MapCommand.self, from: Data(goTo.utf8)) == .goTo(destination: .named(name: "Ronda")))

        let encoded = try JSONEncoder().encode(MapCommand.turn(degrees: -45))
        #expect(try JSONDecoder().decode(MapCommand.self, from: encoded) == .turn(degrees: -45))
    }
}

struct SpokenCommandTests {
    @Test
    func unitsAreConvertedInCode() {
        let feet = SpokenCommand(action: .climb, amount: 1000, unit: .feet, place: nil, direction: nil)
        #expect(feet.mapCommand(altitude: 300) == .climb(meters: 304.8))
        let km = SpokenCommand(action: .descend, amount: 2, unit: .kilometers, place: nil, direction: nil)
        #expect(km.mapCommand(altitude: 300) == .climb(meters: -2_000))
        let miles = SpokenCommand(action: .moveForward, amount: 1, unit: .miles, place: nil, direction: nil)
        #expect(miles.mapCommand(altitude: 300) == .move(forwardMeters: 1_609.344, rightMeters: 0))
    }

    @Test
    func missingAmountsScaleWithAltitude() {
        #expect(SpokenCommand(action: .climb, amount: nil, unit: nil, place: nil, direction: nil)
            .mapCommand(altitude: 300) == .climb(meters: 300))
        #expect(SpokenCommand(action: .turnLeft, amount: nil, unit: nil, place: nil, direction: nil)
            .mapCommand(altitude: 300) == .turn(degrees: -90))
        #expect(SpokenCommand(action: .zoomIn, amount: nil, unit: nil, place: nil, direction: nil)
            .mapCommand(altitude: 300) == .setAltitude(meters: 150))
    }

    @Test
    func goToNeedsAPlace() {
        #expect(SpokenCommand(action: .goTo, amount: nil, unit: nil, place: " ", direction: nil).mapCommand(altitude: 1) == nil)
        #expect(SpokenCommand(action: .goTo, amount: nil, unit: nil, place: "Ronda", direction: nil)
            .mapCommand(altitude: 1) == .goTo(destination: .named(name: "Ronda")))
    }
}

struct PlaceNameTests {
    private let places = [
        Place(id: "san-francisco", name: "San Francisco", latitude: 37.8, longitude: -122.4, radius: 600),
        Place(id: "ronda", name: "Puente Nuevo, Ronda", latitude: 36.7, longitude: -5.2, radius: 400),
    ]

    @Test
    func savedPlacesMatchWholeNamesLoosely() {
        #expect(PlaceLibrary.place(named: "san francisco", in: places)?.id == "san-francisco")
        #expect(PlaceLibrary.place(named: "Puente Nuevo Ronda", in: places)?.id == "ronda")
        #expect(PlaceLibrary.place(named: "ronda", in: places)?.id == "ronda")
        #expect(PlaceLibrary.place(named: "San Francisco airport", in: places) == nil)
    }
}
