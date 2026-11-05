import Foundation
import Testing

/// The MCP tools build MapCommand JSON by hand (the CLI doesn't link the
/// map); these pin that it decodes to the commands meant.
struct ControlToolsTests {
    private func command(_ tool: String, _ arguments: JSONValue) throws -> (MapCommand, String?) {
        let (method, params) = try ControlTools.request(for: tool, arguments: arguments)
        #expect(method == "command.run")
        let value = try #require(params?["command"])
        return (try value.decode(MapCommand.self), params?["wait"]?.string)
    }

    @Test
    func motionToolsBecomeMapCommands() throws {
        #expect(try command("climb", ["meters": 304.8]).0 == .climb(meters: 304.8))
        #expect(try command("set_altitude", ["meters": 150]).0 == .setAltitude(meters: 150))
        #expect(try command("turn", ["degrees": -45]).0 == .turn(degrees: -45))
        #expect(try command("face", ["heading_degrees": 90]).0 == .face(headingDegrees: 90))
        #expect(try command("move", ["forward_meters": 2000]).0 == .move(forwardMeters: 2000, rightMeters: 0))
        #expect(try command("move", ["forward_meters": -5, "right_meters": 10]).0 == .move(forwardMeters: -5, rightMeters: 10))
        #expect(try command("pitch", ["degrees": -15]).0 == .pitch(degrees: -15))
    }

    @Test
    func goToTakesANameOrACoordinate() throws {
        #expect(try command("go_to", ["place": "Eiffel Tower"]).0 == .goTo(destination: .named(name: "Eiffel Tower")))
        #expect(try command("go_to", ["latitude": 36.7418, "longitude": -5.167, "radius_meters": 500]).0
            == .goTo(destination: .coordinate(latitude: 36.7418, longitude: -5.167, radius: 500)))
        #expect(try command("go_to", ["latitude": 1, "longitude": 2]).0
            == .goTo(destination: .coordinate(latitude: 1, longitude: 2, radius: nil)))
        #expect(throws: (any Error).self) { try ControlTools.request(for: "go_to", arguments: [:]) }
        #expect(throws: (any Error).self) { try ControlTools.request(for: "go_to", arguments: ["latitude": 91, "longitude": 0]) }
    }

    @Test
    func motionsWaitUnlessToldNotTo() throws {
        #expect(try command("climb", ["meters": 1]).1 == "finished")
        #expect(try command("climb", ["meters": 1, "wait": false]).1 == "started")
    }

    @Test
    func missingOrNonNumericAmountsAreRejected() {
        #expect(throws: (any Error).self) { try ControlTools.request(for: "climb", arguments: [:]) }
        #expect(throws: (any Error).self) { try ControlTools.request(for: "turn", arguments: ["degrees": "left"]) }
    }

    @Test
    func rawCommandsPassThrough() throws {
        #expect(try command("run_command", ["command": ["climb": ["meters": 10]]]).0 == .climb(meters: 10))
    }

    @Test
    func everyToolHasAnObjectSchemaAndAUniqueName() {
        let names = ControlTools.all.map(\.name)
        #expect(Set(names).count == names.count)
        for tool in ControlTools.all {
            #expect(tool.inputSchema["type"]?.string == "object", "\(tool.name)")
        }
        #expect(ControlTools.localTools.isSubset(of: Set(names)))
        // Tools without arguments map straight to a host method.
        #expect((try? ControlTools.request(for: "get_state", arguments: [:]))?.method == "state.get")
        #expect((try? ControlTools.request(for: "list_places", arguments: [:]))?.method == "places.list")
    }

    @Test
    func jsonValuesRoundTrip() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": false]]
        #expect(try JSONValue.parse(value.jsonString) == value)
    }
}
