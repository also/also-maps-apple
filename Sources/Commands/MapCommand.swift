import Foundation

/// A discrete instruction to the map, from any source: voice today, and
/// later an external controller (an MCP server, the iPhone remote). Codable
/// so it can cross a process or network boundary as JSON; see
/// docs/commands.md. Amounts are SI units (metres, degrees) so every source
/// converts the same way, outside the map.
enum MapCommand: Codable, Equatable, Sendable {
    /// Jump to a place, framed like a saved place.
    case goTo(destination: MapDestination)
    /// Change height by `meters` (negative descends); latitude, longitude
    /// and heading stay.
    case climb(meters: Double)
    /// Set height above the ground under the camera.
    case setAltitude(meters: Double)
    /// Turn in place, `degrees` clockwise seen from above (negative turns
    /// left).
    case turn(degrees: Double)
    /// Turn in place to face a compass heading, degrees clockwise from north.
    case face(headingDegrees: Double)
    /// Travel along the globe at constant height, along and across the
    /// direction of travel.
    case move(forwardMeters: Double, rightMeters: Double)
    /// Look up (+) or down (−) by `degrees`. Hosts that set pitch themselves
    /// (visionOS) ignore it.
    case pitch(degrees: Double)

    /// One line for logs and the voice trace.
    var summary: String {
        switch self {
        case let .goTo(destination): "go to \(destination.summary)"
        case let .climb(meters): meters < 0 ? "descend \(Self.metres(-meters))" : "climb \(Self.metres(meters))"
        case let .setAltitude(meters): "altitude \(Self.metres(meters))"
        case let .turn(degrees): degrees < 0 ? "turn left \(Self.degrees(-degrees))" : "turn right \(Self.degrees(degrees))"
        case let .face(heading): "face \(Self.degrees(heading))"
        case let .move(forward, right): "move \(Self.metres(forward)) forward, \(Self.metres(right)) right"
        case let .pitch(degrees): degrees < 0 ? "look down \(Self.degrees(-degrees))" : "look up \(Self.degrees(degrees))"
        }
    }

    private static func metres(_ value: Double) -> String { String(format: "%.0f m", value) }
    private static func degrees(_ value: Double) -> String { String(format: "%.0f°", value) }
}

/// Where `goTo` goes: a name to look up, or a position.
enum MapDestination: Codable, Equatable, Sendable {
    /// A saved place's id or name, or anything a map search would find
    /// ("Eiffel Tower", "Ronda, Spain").
    case named(name: String)
    /// `radius` is the view's half-width, metres, as in a saved place.
    case coordinate(latitude: Double, longitude: Double, radius: Double?)

    var summary: String {
        switch self {
        case let .named(name): "“\(name)”"
        case let .coordinate(latitude, longitude, _): String(format: "%.5f, %.5f", latitude, longitude)
        }
    }
}

/// What a map can do with a command once any lookup is done. The map
/// owns how it's animated and limited; it reports what it actually did.
@MainActor
protocol MapCommandTarget: AnyObject {
    func go(to place: Place)
    /// Starts `motion` from wherever the camera is, replacing any
    /// unfinished one.
    func begin(_ motion: CommandMotion)
    /// The view now, for answering relative questions.
    var commandCamera: CameraPose { get }
    /// Height above the ground under the camera, metres.
    var commandAltitude: Double { get }
}

/// The outcome of one command, for the trace and an external caller.
struct MapCommandResult: Sendable, Equatable {
    var command: MapCommand
    var ok: Bool
    var detail: String
}
