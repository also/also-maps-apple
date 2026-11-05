import Foundation
import Observation

/// Voice control: listen, transcribe on device, interpret with Apple
/// Intelligence, run the commands on the map. Every step is recorded in
/// `turns`, for the trace panel.
///
/// Push to talk: hold the button, key or controller button while speaking.
/// A short press instead starts listening until a pause, or the next press.
@MainActor
@Observable
final class VoiceControl {
    enum Phase: Equatable {
        case idle, starting, listening, interpreting, running
    }

    /// One spoken request, from the first word to the commands' results.
    struct Turn: Identifiable {
        struct Step {
            var spoken: SpokenCommand
            var command: MapCommand?
            var result: MapCommandResult?
        }

        let id = UUID()
        let started = Date()
        /// Settled text, and what's being recognised after it.
        var finalText = ""
        var volatileText = ""
        var heldToTalk = false
        var listenSeconds: Double?
        /// The model's output: its plan as JSON, or its reply after the
        /// tool calls.
        var modelOutput: String?
        var toolCalls: [MapToolCalls.Call] = []
        var modelSeconds: Double?
        var steps: [Step] = []
        var error: String?

        var transcript: String {
            [finalText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private(set) var phase = Phase.idle
    private(set) var turns: [Turn] = []
    /// Shown above the turns: why voice can't work here, if it can't.
    var unavailableReason: String? { CommandInterpreter.unavailableReason }
    private(set) var localeName: String?

    let runner: MapCommandRunner
    private let listener = SpeechListener()
    private let interpreter = CommandInterpreter()
    private var pressedAt: ContinuousClock.Instant?
    private var heldToTalk = false
    private var listeningStarted: ContinuousClock.Instant?
    private var stopRequested = false

    /// How long a press must last to count as holding to talk, seconds.
    private static let holdThreshold = 0.35
    private static let keptTurns = 30

    init(target: MapCommandTarget? = nil) {
        runner = MapCommandRunner(target: target)
    }

    // MARK: Push to talk

    /// The talk button, key or controller button went down.
    func press() {
        switch phase {
        case .idle:
            pressedAt = .now
            heldToTalk = false
            startListening()
        case .starting, .listening:
            // A second press ends a short-press listen.
            if !heldToTalk { finishListening() }
        case .interpreting, .running:
            break
        }
    }

    /// The talk button, key or controller button came up.
    func release() {
        guard let pressedAt else { return }
        self.pressedAt = nil
        let held = ContinuousClock.now - pressedAt
        if held >= .milliseconds(Int(Self.holdThreshold * 1000)) {
            heldToTalk = true
            if !turns.isEmpty { turns[0].heldToTalk = true }
            finishListening()
        }
    }

    /// A tap on an on-screen button: listen until a pause, or stop.
    func toggle() {
        press()
        pressedAt = nil
    }

    func clearTrace() {
        guard phase == .idle else { return }
        turns.removeAll()
    }

    /// Runs a typed request through the same interpretation as speech:
    /// for trying the model without a microphone.
    func submit(text: String) {
        guard phase == .idle, !text.isEmpty else { return }
        var turn = Turn()
        turn.finalText = text
        record(turn)
        Task { await interpretAndRun() }
    }

    /// Debug: ALSOMAPS_VOICE="ascend 1000 ft; go to Ronda" submits each
    /// request in turn once the map has had `delay` seconds to start.
    func runFromEnvironment(delay: Double = 4) {
        guard let script = ProcessInfo.processInfo.environment["ALSOMAPS_VOICE"] else { return }
        let requests = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            for request in requests where !request.isEmpty {
                while phase != .idle { try? await Task.sleep(for: .milliseconds(100)) }
                submit(text: request)
                try? await Task.sleep(for: .milliseconds(100))
                while phase != .idle { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Pipeline

    private var placeNames: [String] { PlaceLibrary.all.map(\.name) }

    private func startListening() {
        phase = .starting
        stopRequested = false
        record(Turn())
        interpreter.prewarm(placeNames: placeNames)
        Task {
            do {
                try await listener.start(
                    contextualStrings: placeNames + ["ascend", "descend", "altitude"],
                    onEvent: { [weak self] event in self?.heard(event) },
                    onFinish: { [weak self] error in self?.recognitionFinished(error) })
                localeName = listener.locale?.identifier
                listeningStarted = .now
                phase = .listening
                // Released or pressed again while the microphone started.
                if stopRequested { finishListening() }
            } catch {
                fail(error)
            }
        }
    }

    private func heard(_ event: SpeechListener.Event) {
        guard !turns.isEmpty else { return }
        switch event {
        case let .volatile(text):
            turns[0].volatileText = text
        case let .final(text):
            turns[0].volatileText = ""
            let text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                turns[0].finalText = [turns[0].finalText, text].filter { !$0.isEmpty }.joined(separator: " ")
            }
            // A short press listens until the first pause.
            if !heldToTalk, pressedAt == nil, phase == .listening, !text.isEmpty { finishListening() }
        }
    }

    private func finishListening() {
        guard phase == .listening else {
            if phase == .starting { stopRequested = true }
            return
        }
        phase = .interpreting
        if let listeningStarted, !turns.isEmpty {
            turns[0].listenSeconds = Self.seconds(since: listeningStarted)
        }
        Task { await listener.stop() }
    }

    /// Recognition has delivered its last result after `stop`.
    private func recognitionFinished(_ error: Error?) {
        if let error {
            fail(error)
            return
        }
        Task { await interpretAndRun() }
    }

    private func interpretAndRun() async {
        guard !turns.isEmpty else { return }
        let transcript = turns[0].transcript
        turns[0].finalText = transcript
        turns[0].volatileText = ""
        guard !transcript.isEmpty else {
            turns[0].error = "Heard nothing"
            phase = .idle
            return
        }
        phase = .interpreting
        do {
            let interpretation = try await interpreter.interpret(transcript, placeNames: placeNames)
            turns[0].modelOutput = interpretation.output
            turns[0].toolCalls = interpretation.toolCalls
            turns[0].modelSeconds = interpretation.seconds
            let altitude = runner.target?.commandAltitude ?? 100
            turns[0].steps = interpretation.plan.commands.map {
                Turn.Step(spoken: $0, command: $0.mapCommand(altitude: altitude))
            }
            if turns[0].steps.isEmpty { turns[0].error = "No map command in that" }
        } catch {
            fail(error)
            return
        }

        phase = .running
        let id = turns[0].id
        defer { if let turn = turns.first(where: { $0.id == id }) { Self.log(turn, camera: runner.target?.commandCamera) } }
        for index in turns[0].steps.indices {
            guard let command = turns.first(where: { $0.id == id })?.steps[index].command else { continue }
            let result = await runner.run(command)
            if let turn = turns.firstIndex(where: { $0.id == id }) { turns[turn].steps[index].result = result }
            if case .goTo = command { continue }
            // Let a motion finish before the next command starts.
            if result.ok { try? await Task.sleep(for: .seconds(CommandMotion().duration)) }
        }
        phase = .idle
    }

    private func fail(_ error: Error) {
        if !turns.isEmpty {
            turns[0].error = error.localizedDescription
            Self.log(turns[0], camera: nil)
        }
        phase = .idle
        Task { await listener.cancel() }
    }

    /// One turn on stdout, for tools reading the Mac app's log.
    private static func log(_ turn: Turn, camera: CameraPose?) {
        #if DEBUG
        var lines = ["[AlsoMaps] voice: “\(turn.transcript)”"]
        if let seconds = turn.modelSeconds { lines.append(String(format: "  model %.2f s: %@", seconds, turn.modelOutput ?? "")) }
        for call in turn.toolCalls { lines.append("  tool \(call.tool) \(call.arguments)") }
        for step in turn.steps {
            lines.append("  → \(step.command?.summary ?? "not a command"): \(step.result.map { ($0.ok ? "ok " : "failed ") + $0.detail } ?? "not run")")
        }
        if let error = turn.error { lines.append("  error: \(error)") }
        if let camera {
            lines.append(String(format: "  camera %.5f, %.5f, %.0f m, heading %.0f°", camera.latitude, camera.longitude,
                                camera.height, camera.heading * 180 / .pi))
        }
        print(lines.joined(separator: "\n"))
        #endif
    }

    private func record(_ turn: Turn) {
        turns.insert(turn, at: 0)
        if turns.count > Self.keptTurns { turns.removeLast() }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
