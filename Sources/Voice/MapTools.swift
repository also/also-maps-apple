import Foundation
import FoundationModels

/// The map's controls as Foundation Models tools. The model calls one per
/// command it hears, in order, or none; calls are collected rather than
/// run, so the voice pipeline can show them and run them in turn. The
/// same set is what an external controller (MCP) would expose.
final class MapToolCalls: @unchecked Sendable {
    struct Call {
        var tool: String
        var arguments: String
        /// Nil for notACommand.
        var command: SpokenCommand?
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func append(_ call: Call) {
        lock.withLock { calls.append(call) }
    }

    func drain() -> [Call] {
        lock.withLock {
            defer { calls = [] }
            return calls
        }
    }

    /// The tools, all reporting into this collector.
    var tools: [any Tool] {
        [GoToTool(calls: self), AltitudeTool(calls: self), TurnTool(calls: self), MoveTool(calls: self),
         LookTool(calls: self), ZoomTool(calls: self), NotACommandTool(calls: self)]
    }

    fileprivate func record(_ tool: String, _ arguments: some ConvertibleToGeneratedContent,
                            _ command: SpokenCommand?) -> String {
        append(Call(tool: tool, arguments: arguments.generatedContent.jsonString, command: command))
        return "Done"
    }
}

private extension SpokenCommand {
    init(_ action: SpokenAction, amount: Double? = nil, unit: SpokenUnit? = nil, place: String? = nil,
         direction: CompassDirection? = nil) {
        self.init(action: action, amount: amount, unit: unit, place: place, direction: direction)
    }
}

struct GoToTool: Tool {
    let calls: MapToolCalls
    let name = "goTo"
    let description = "Fly to a named place: a city, landmark, address or natural feature."

    @Generable
    struct Arguments {
        @Guide(description: "The place name exactly as spoken, including any city or country")
        var place: String
    }

    func call(arguments: Arguments) async throws -> String {
        calls.record(name, arguments, SpokenCommand(.goTo, place: arguments.place))
    }
}

struct AltitudeTool: Tool {
    let calls: MapToolCalls
    let name = "changeAltitude"
    let description = """
        Go up or down by an amount ("ascend 1000 feet", "go lower"), \
        or to a height ("go to 500 feet", "altitude 2 kilometers").
        """

    @Generable
    enum Change: String { case up, down, to }

    @Generable
    struct Arguments {
        @Guide(description: "up or down by the amount, or to the amount as a height")
        var change: Change
        @Guide(description: "The number spoken: 1000 in \"ascend 1000 feet\", 500 in \"go to 500 feet\"")
        var amount: Double?
        var unit: SpokenUnit?
    }

    func call(arguments: Arguments) async throws -> String {
        let action: SpokenAction = switch arguments.change {
        case .up: .climb
        case .down: .descend
        case .to: .setAltitude
        }
        return calls.record(name, arguments, SpokenCommand(action, amount: arguments.amount, unit: arguments.unit))
    }
}

struct TurnTool: Tool {
    let calls: MapToolCalls
    let name = "turn"
    let description = "Turn left or right in place, or to face a compass direction."

    @Generable
    enum Towards: String { case left, right, north, northeast, east, southeast, south, southwest, west, northwest }

    @Generable
    struct Arguments {
        var towards: Towards
        @Guide(description: "Degrees to turn left or right, if spoken")
        var degrees: Double?
    }

    func call(arguments: Arguments) async throws -> String {
        let command = switch arguments.towards {
        case .left: SpokenCommand(.turnLeft, amount: arguments.degrees)
        case .right: SpokenCommand(.turnRight, amount: arguments.degrees)
        default: SpokenCommand(.face, direction: CompassDirection(rawValue: arguments.towards.rawValue))
        }
        return calls.record(name, arguments, command)
    }
}

struct MoveTool: Tool {
    let calls: MapToolCalls
    let name = "move"
    let description = "Fly forward, back, left or right at the same height."

    @Generable
    enum Direction: String { case forward, back, left, right }

    @Generable
    struct Arguments {
        var direction: Direction
        @Guide(description: "The distance spoken, if any")
        var amount: Double?
        var unit: SpokenUnit?
    }

    func call(arguments: Arguments) async throws -> String {
        let action: SpokenAction = switch arguments.direction {
        case .forward: .moveForward
        case .back: .moveBack
        case .left: .moveLeft
        case .right: .moveRight
        }
        return calls.record(name, arguments, SpokenCommand(action, amount: arguments.amount, unit: arguments.unit))
    }
}

struct LookTool: Tool {
    let calls: MapToolCalls
    let name = "look"
    let description = "Tilt the view up or down."

    @Generable
    enum Direction: String { case up, down }

    @Generable
    struct Arguments {
        var direction: Direction
        var degrees: Double?
    }

    func call(arguments: Arguments) async throws -> String {
        calls.record(name, arguments, SpokenCommand(arguments.direction == .up ? .lookUp : .lookDown,
                                                    amount: arguments.degrees))
    }
}

struct ZoomTool: Tool {
    let calls: MapToolCalls
    let name = "zoom"
    let description = "Zoom in (closer) or out (farther)."

    @Generable
    enum Direction: String { case `in`, out }

    @Generable
    struct Arguments {
        var direction: Direction
        @Guide(description: "How many times closer or farther, if spoken")
        var factor: Double?
    }

    func call(arguments: Arguments) async throws -> String {
        calls.record(name, arguments, SpokenCommand(arguments.direction == .in ? .zoomIn : .zoomOut,
                                                    amount: arguments.factor))
    }
}

/// Somewhere for words that aren't map commands to go: without it the
/// small model tends to pick a map tool anyway.
struct NotACommandTool: Tool {
    let calls: MapToolCalls
    let name = "notACommand"
    let description = "The words aren't a request to move or turn the map: chatter, a question, noise."

    @Generable
    struct Arguments {
        @Guide(description: "Why it isn't a map command, in a few words")
        var reason: String
    }

    func call(arguments: Arguments) async throws -> String {
        calls.record(name, arguments, nil)
    }
}
