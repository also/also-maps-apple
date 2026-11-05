import Foundation
import FoundationModels

/// Turns a transcript into map commands with the on-device Apple
/// Intelligence model, in one of two ways (compared by InterpreterTests):
/// tool calls, one per command, or guided generation of a whole plan.
@MainActor
final class CommandInterpreter {
    enum Mode: String, CaseIterable {
        /// The model calls a map tool per command (MapTools), or none.
        case tools
        /// The model can only answer with a valid `VoicePlan`.
        case guided
    }

    struct Interpretation {
        var plan: VoicePlan
        /// The tools called, in order (tools mode).
        var toolCalls: [MapToolCalls.Call] = []
        /// The model's output: the plan as JSON, or its closing reply.
        var output: String
        var seconds: Double
    }

    let mode: Mode
    private let calls = MapToolCalls()

    init(mode: Mode = .tools) {
        self.mode = mode
    }

    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case let .unavailable(reason): "Apple Intelligence is unavailable: \(reason)"
            }
        }
    }

    /// Why the model can't be used, or nil if it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "this device doesn’t support it"
        case .unavailable(.appleIntelligenceNotEnabled): "it’s turned off in Settings"
        case .unavailable(.modelNotReady): "the model is still downloading"
        case let .unavailable(other): "\(other)"
        }
    }

    private var session: LanguageModelSession?

    /// Loads the model ahead of a request, while the user is still talking.
    func prewarm(placeNames: [String] = []) {
        guard Self.unavailableReason == nil else { return }
        let session = makeSession(placeNames: placeNames)
        session.prewarm()
        self.session = session
    }

    func interpret(_ transcript: String, placeNames: [String]) async throws -> Interpretation {
        if let reason = Self.unavailableReason { throw Failure.unavailable(reason) }
        // A fresh session per request: commands don't depend on earlier ones,
        // and the context stays small.
        let session = self.session ?? makeSession(placeNames: placeNames)
        self.session = nil
        let start = ContinuousClock.now
        var interpretation: Interpretation
        switch mode {
        case .guided:
            let response = try await session.respond(to: transcript, generating: VoicePlan.self,
                                                     options: GenerationOptions(sampling: .greedy))
            interpretation = Interpretation(plan: response.content, output: response.rawContent.jsonString,
                                            seconds: 0)
        case .tools:
            _ = calls.drain()
            let response = try await session.respond(to: transcript, options: GenerationOptions(sampling: .greedy))
            let made = Self.inCallOrder(calls.drain(), transcript: session.transcript)
            interpretation = Interpretation(plan: VoicePlan(commands: made.compactMap(\.command)), toolCalls: made,
                                            output: response.content, seconds: 0)
        }
        let elapsed = ContinuousClock.now - start
        interpretation.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return interpretation
    }

    /// Tools can run concurrently, so they record in any order; the
    /// transcript has the order the model called them in, which is the
    /// order spoken. Calls not found there keep their place at the end.
    private static func inCallOrder(_ made: [MapToolCalls.Call], transcript: Transcript) -> [MapToolCalls.Call] {
        var remaining = made
        var ordered: [MapToolCalls.Call] = []
        for entry in transcript {
            guard case let .toolCalls(toolCalls) = entry else { continue }
            for call in toolCalls {
                let arguments = call.arguments.jsonString
                if let index = remaining.firstIndex(where: { $0.tool == call.toolName && $0.arguments == arguments }) {
                    ordered.append(remaining.remove(at: index))
                }
            }
        }
        return ordered + remaining
    }

    /// The saved places aren't listed: the model then offers them for
    /// requests that name no place. Speech recognition is biased toward
    /// them instead (SpeechListener).
    private func makeSession(placeNames: [String]) -> LanguageModelSession {
        switch mode {
        case .tools: toolSession()
        case .guided: guidedSession()
        }
    }

    private func toolSession() -> LanguageModelSession {
        LanguageModelSession(tools: calls.tools, instructions: """
            You control a 3D map by voice. For each map command the user asks for, call the matching tool, \
            in the order spoken. A request can have several commands. \
            Keep numbers and units exactly as spoken; don't convert them, and leave amounts out if none was said. \
            "Go to" a height ("go to 500 feet") is changeAltitude to that amount; "go to" a place is goTo. \
            If the words aren't a request to move the map, call notACommand. \
            After the calls, reply with one short sentence.
            """)
    }

    private func guidedSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            You control a 3D map by voice. List each map command the user asks for, in order. \
            Keep numbers and units exactly as spoken; don't convert them, and leave amount out if no number was said. \
            Only goTo has a place, and only face has a direction. \
            If the words aren't a request to move the map, give no commands.

            Examples:
            "ascend 1000 ft" → climb, amount 1000, unit feet
            "go lower" → descend
            "go to 500 feet" → setAltitude, amount 500, unit feet
            "fly to Boston" → goTo, place Boston
            "show me Mount Fuji" → goTo, place Mount Fuji
            "face east" → face, direction east
            "turn left 30 degrees" → turnLeft, amount 30, unit degrees
            "fly forward 2 kilometers" → moveForward, amount 2, unit kilometers
            "climb 100 meters then turn right" → climb, amount 100, unit meters; turnRight
            "zoom in" → zoomIn
            "what time is it" → no commands
            """)
    }
}
