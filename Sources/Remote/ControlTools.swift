import Foundation

/// The MCP tools `alsomaps-control mcp` offers, and the host request each
/// map tool becomes. Foundation-only: shared by the CLI and the tests,
/// which check that each command it builds decodes as a `MapCommand`.
struct ControlTool {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

enum ControlTools {
    struct ArgumentError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Tools the CLI answers itself rather than passing to the host.
    static let localTools: Set<String> = ["list_devices", "connect", "recent_events"]

    static let all: [ControlTool] = [
        ControlTool(
            name: "list_devices",
            description: "List Also Maps apps on this Mac and the local network that allow remote control, and which one is connected.",
            inputSchema: schema([:])),
        ControlTool(
            name: "connect",
            description: "Connect to an Also Maps app. Use \"local\" for the Debug Mac app on this Mac (no code needed), or a name from list_devices with the 6-digit code its Remote Control panel shows. Map tools connect to \"local\" by themselves if nothing is connected.",
            inputSchema: schema([
                "device": ["type": "string", "description": "\"local\", or a device name (or part of one) from list_devices"],
                "code": ["type": "string", "description": "The 6-digit pairing code shown on the device. Remembered once it works."],
            ], required: ["device"])),
        ControlTool(
            name: "go_to",
            description: "Jump the map to a place: a saved place's name, anything a map search finds (\"Eiffel Tower\", \"Ronda, Spain\"), or a coordinate. The view is framed to the place's size.",
            inputSchema: schema([
                "place": ["type": "string", "description": "A name to look up. Leave out to use latitude and longitude."],
                "latitude": ["type": "number"],
                "longitude": ["type": "number"],
                "radius_meters": ["type": "number", "description": "Half-width of the view around the coordinate, metres. Default 1000."],
            ])),
        motionTool("climb", "Climb (positive) or descend (negative) by a number of metres, keeping position and heading.",
                   ["meters": ["type": "number", "description": "Metres; negative descends."]], required: ["meters"]),
        motionTool("set_altitude", "Climb or descend to a height above the ground under the camera.",
                   ["meters": ["type": "number", "description": "Height above the ground, metres."]], required: ["meters"]),
        motionTool("turn", "Turn in place: positive turns right (clockwise seen from above), negative left.",
                   ["degrees": ["type": "number"]], required: ["degrees"]),
        motionTool("face", "Turn in place to face a compass heading.",
                   ["heading_degrees": ["type": "number", "description": "Degrees clockwise from north: 0 north, 90 east."]],
                   required: ["heading_degrees"]),
        motionTool("move", "Travel along the ground at constant height, relative to the direction you're facing.",
                   ["forward_meters": ["type": "number", "description": "Negative goes back."],
                    "right_meters": ["type": "number", "description": "Negative goes left. Default 0."]],
                   required: ["forward_meters"]),
        motionTool("pitch", "Look up (positive) or down (negative). Ignored on Vision Pro, which sets pitch itself.",
                   ["degrees": ["type": "number"]], required: ["degrees"]),
        ControlTool(
            name: "run_command",
            description: "Run one map command as raw MapCommand JSON, for commands without their own tool. Shapes: {\"goTo\":{\"destination\":{\"named\":{\"name\":\"…\"}}}}, {\"climb\":{\"meters\":100}}, {\"setAltitude\":{\"meters\":150}}, {\"turn\":{\"degrees\":-45}}, {\"face\":{\"headingDegrees\":90}}, {\"move\":{\"forwardMeters\":2000,\"rightMeters\":0}}, {\"pitch\":{\"degrees\":-15}}.",
            inputSchema: schema([
                "command": ["type": "object", "description": "A MapCommand as JSON."],
                "wait": waitProperty,
            ], required: ["command"])),
        ControlTool(
            name: "get_state",
            description: "The camera (latitude, longitude, height, heading, pitch), height above the ground, whether a motion is running, and how far tile loading has got.",
            inputSchema: schema([:])),
        ControlTool(
            name: "list_places",
            description: "The map's saved places, which go_to also accepts by name.",
            inputSchema: schema([:])),
        ControlTool(
            name: "wait_until_settled",
            description: "Wait until the tiles for the current view have loaded (or the timeout passes), before judging what's on screen.",
            inputSchema: schema([
                "timeout_seconds": ["type": "number", "description": "Default 30."],
            ])),
        ControlTool(
            name: "perform_action",
            description: "Press one of the map's buttons: previousPlace or nextPlace (step through saved places), faceNorth, toggleFly (Vision Pro: hold tiles and fly through what's loaded).",
            inputSchema: schema([
                "action": ["type": "string", "enum": ["previousPlace", "nextPlace", "faceNorth", "toggleFly"]],
            ], required: ["action"])),
        ControlTool(
            name: "recent_events",
            description: "Events from the connected map since a sequence number: camera moves (twice a second at most), motion.finished, tiles.settled, and every command run, including the user's voice commands.",
            inputSchema: schema([
                "after": ["type": "number", "description": "Return events with a sequence number above this. Default: the last 20."],
            ])),
        ControlTool(
            name: "call_method",
            description: "Call any host method directly, for methods newer than these tools. get_state's answer lists none; the host's hello lists them (see list_devices).",
            inputSchema: schema([
                "method": ["type": "string"],
                "params": ["type": "object"],
            ], required: ["method"])),
    ]

    /// The host request for a map tool: method, params, and how long to
    /// allow for the answer.
    static func request(for tool: String, arguments: JSONValue) throws -> (method: String, params: JSONValue?) {
        let wait: JSONValue = .string((arguments["wait"]?.bool ?? true) ? "finished" : "started")
        func number(_ key: String) throws -> Double {
            guard let value = arguments[key]?.number, value.isFinite else {
                throw ArgumentError("\(tool) needs a number \(key)")
            }
            return value
        }
        func command(_ command: JSONValue) -> (String, JSONValue?) {
            ("command.run", ["command": command, "wait": wait])
        }
        switch tool {
        case "go_to":
            if let place = arguments["place"]?.string, !place.isEmpty {
                return command(["goTo": ["destination": ["named": ["name": .string(place)]]]])
            }
            guard arguments["latitude"] != nil || arguments["longitude"] != nil else {
                throw ArgumentError("go_to needs a place, or a latitude and longitude")
            }
            let latitude = try number("latitude")
            let longitude = try number("longitude")
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw ArgumentError("go_to: latitude must be within ±90 and longitude within ±180")
            }
            var coordinate: [String: JSONValue] = ["latitude": .number(latitude), "longitude": .number(longitude)]
            if let radius = arguments["radius_meters"]?.number { coordinate["radius"] = .number(radius) }
            return command(["goTo": ["destination": ["coordinate": .object(coordinate)]]])
        case "climb":
            return try command(["climb": ["meters": .number(number("meters"))]])
        case "set_altitude":
            return try command(["setAltitude": ["meters": .number(number("meters"))]])
        case "turn":
            return try command(["turn": ["degrees": .number(number("degrees"))]])
        case "face":
            return try command(["face": ["headingDegrees": .number(number("heading_degrees"))]])
        case "move":
            let right = arguments["right_meters"]?.number ?? 0
            return try command(["move": ["forwardMeters": .number(number("forward_meters")), "rightMeters": .number(right)]])
        case "pitch":
            return try command(["pitch": ["degrees": .number(number("degrees"))]])
        case "run_command":
            guard let raw = arguments["command"], case .object = raw else {
                throw ArgumentError("run_command needs a command object")
            }
            return command(raw)
        case "get_state":
            return ("state.get", nil)
        case "list_places":
            return ("places.list", nil)
        case "wait_until_settled":
            return ("tiles.waitSettled", ["timeoutSeconds": .number(arguments["timeout_seconds"]?.number ?? 30)])
        case "perform_action":
            guard let action = arguments["action"]?.string else { throw ArgumentError("perform_action needs an action") }
            return ("action.perform", ["action": .string(action)])
        case "call_method":
            guard let method = arguments["method"]?.string else { throw ArgumentError("call_method needs a method") }
            return (method, arguments["params"])
        default:
            throw ArgumentError("Unknown tool \(tool)")
        }
    }

    // MARK: Schemas

    private static let waitProperty: JSONValue = [
        "type": "boolean",
        "description": "Wait until the motion has finished before answering. Default true.",
    ]

    private static func motionTool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                                   required: [String]) -> ControlTool {
        var properties = properties
        properties["wait"] = waitProperty
        return ControlTool(name: name, description: description + " Eased over about a second.",
                           inputSchema: schema(properties, required: required))
    }

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }
}
