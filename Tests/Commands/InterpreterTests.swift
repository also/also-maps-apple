import Foundation
import Testing

/// Phrases through the real on-device model. Slow and needs Apple
/// Intelligence, so off unless ALSOMAPS_MODEL_TESTS=1 (pass it to
/// xcodebuild as TEST_RUNNER_ALSOMAPS_MODEL_TESTS=1).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ALSOMAPS_MODEL_TESTS"] == "1"))
struct InterpreterTests {
    private let places = ["San Francisco", "Boston", "New York", "Chicago", "Grand Canyon", "Puente Nuevo, Ronda"]

    private static var mode: CommandInterpreter.Mode {
        ProcessInfo.processInfo.environment["ALSOMAPS_MODEL_MODE"].flatMap(CommandInterpreter.Mode.init) ?? .tools
    }

    private func commands(_ phrase: String, altitude: Double = 500) async throws -> [MapCommand?] {
        let interpretation = try await CommandInterpreter(mode: Self.mode).interpret(phrase, placeNames: places)
        let calls = interpretation.toolCalls.map { "\($0.tool)\($0.arguments)" }.joined(separator: " ")
        print("[model \(Self.mode)] \(phrase) → \(calls) \(interpretation.output) (\(String(format: "%.2f", interpretation.seconds)) s)")
        return interpretation.plan.commands.map { $0.mapCommand(altitude: altitude) }
    }

    @Test(arguments: [
        ("ascend 1000 ft", MapCommand.climb(meters: 304.8)),
        ("go up 200 feet", .climb(meters: 60.96)),
        ("descend 50 meters", .climb(meters: -50)),
        ("go to 500 feet", .setAltitude(meters: 152.4)),
        ("turn left 45 degrees", .turn(degrees: -45)),
        ("face east", .face(headingDegrees: 90)),
        ("go to Boston", .goTo(destination: .named(name: "Boston"))),
        ("take me to the Eiffel Tower", .goTo(destination: .named(name: "Eiffel Tower"))),
        ("fly forward 2 kilometers", .move(forwardMeters: 2_000, rightMeters: 0)),
        ("ascend two hundred feet", .climb(meters: 60.96)),
        ("face south west", .face(headingDegrees: 225)),
        ("go to Ronda", .goTo(destination: .named(name: "Ronda"))),
    ])
    func phrase(_ phrase: String, expected: MapCommand) async throws {
        let commands = try await commands(phrase)
        #expect(commands.count == 1)
        #expect(commands.first == expected)
    }

    /// Both are found, but the model doesn't reliably call them in the
    /// order spoken (it turned first here, consistently).
    @Test
    func severalCommands() async throws {
        let commands = try await commands("go up 50 meters and turn left")
        #expect(commands.count == 2)
        #expect(commands.contains(.climb(meters: 50)))
        #expect(commands.contains(.turn(degrees: -90)))
    }

    @Test
    func chatterIsNotACommand() async throws {
        #expect(try await commands("what a lovely day").isEmpty)
    }
}
