import SwiftUI

/// The talk button: tap to listen until a pause, or press and hold while
/// speaking. Shows what voice control is doing.
struct VoiceButton: View {
    let voice: VoiceControl
    @State private var pressing = false

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .frame(width: 44, height: 44)
            .foregroundStyle(voice.phase == .listening ? .white : .primary)
            .background(background, in: .circle)
            .contentShape(.circle)
            .symbolEffect(.pulse, isActive: voice.phase == .listening || voice.phase == .interpreting)
            // Down and up, so holding works as push to talk.
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    voice.press()
                }
                .onEnded { _ in
                    pressing = false
                    voice.release()
                })
            .accessibilityLabel("Voice control")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { voice.toggle() }
    }

    private var symbol: String {
        switch voice.phase {
        case .idle: "mic"
        case .starting, .listening: "mic.fill"
        case .interpreting: "ellipsis"
        case .running: "location.fill"
        }
    }

    private var background: AnyShapeStyle {
        voice.phase == .listening ? AnyShapeStyle(.red) : AnyShapeStyle(.regularMaterial)
    }
}

/// How voice control is working: each request's recognised speech, the
/// model's interpretation, the commands it became and what they did.
struct VoiceTraceView: View {
    let voice: VoiceControl
    /// Typing in the field: the map should stop reading keys meanwhile.
    var typingChanged: (Bool) -> Void = { _ in }
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VoiceButton(voice: voice)
                VStack(alignment: .leading) {
                    Text(status).font(.headline)
                    Text(Self.hint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear", systemImage: "trash") { voice.clearTrace() }
                    .labelStyle(.iconOnly)
                    .disabled(voice.turns.isEmpty || voice.phase != .idle)
            }
            if let reason = voice.unavailableReason {
                Label("Apple Intelligence is unavailable: \(reason)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            TextField("Or type a command", text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    voice.submit(text: typed)
                    typed = ""
                }
                .disabled(voice.phase != .idle)
                .focused($typing)
                .onChange(of: typing) { _, typing in typingChanged(typing) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(voice.turns) { turn in
                        TurnView(turn: turn)
                        Divider()
                    }
                }
            }
        }
        .padding(12)
    }

    static let hint = "Tap, or hold while speaking: Space, RB on a controller. “Go to Boston”, “ascend 1000 feet”."

    private var status: String {
        switch voice.phase {
        case .idle: "Voice control"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .interpreting: "Interpreting"
        case .running: "Running"
        }
    }
}

private struct TurnView: View {
    let turn: VoiceControl.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                (Text(turn.finalText) + Text(turn.volatileText.isEmpty ? "" : " " + turn.volatileText)
                    .foregroundStyle(.secondary))
                    .font(.body.weight(.medium))
                Spacer()
                Text(timing).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(Array(turn.toolCalls.enumerated()), id: \.offset) { _, call in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(.tertiary)
                    Text(call.tool).fontWeight(.semibold)
                    Text(call.arguments).foregroundStyle(.secondary)
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
            if let output = turn.modelOutput {
                Text(output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 4))
            }
            ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                StepView(step: step)
            }
            if let error = turn.error {
                Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var timing: String {
        var parts: [String] = []
        if let listen = turn.listenSeconds { parts.append(String(format: "heard %.1fs", listen)) }
        if let model = turn.modelSeconds { parts.append(String(format: "model %.2fs", model)) }
        if turn.heldToTalk { parts.append("held") }
        return parts.joined(separator: " · ")
    }
}

private struct StepView: View {
    let step: VoiceControl.Turn.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(spoken).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Text(step.command?.summary ?? "not a command").fontWeight(.medium)
            }
            if let result = step.result {
                Label(result.detail, systemImage: result.ok ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(result.ok ? .green : .red)
            }
        }
        .font(.caption)
    }

    private var spoken: String {
        let spoken = step.spoken
        var words = [spoken.action.rawValue]
        if let amount = spoken.amount { words.append(String(format: "%g", amount)) }
        if let unit = spoken.unit { words.append(unit.rawValue) }
        if let place = spoken.place { words.append("“\(place)”") }
        return words.joined(separator: " ")
    }
}

/// Voice control over a map: the talk button with the latest request, which
/// opens into the full trace.
struct VoicePanel: View {
    let voice: VoiceControl
    var typingChanged: (Bool) -> Void = { _ in }
    @AppStorage("voiceTraceShown") private var expanded = false

    var body: some View {
        Group {
            if expanded {
                VoiceTraceView(voice: voice, typingChanged: typingChanged)
                    .frame(width: 380)
                    .frame(maxHeight: 520)
                    .overlay(alignment: .topTrailing) { collapse }
            } else {
                HStack(spacing: 8) {
                    if let turn = voice.turns.first {
                        latest(turn)
                    }
                    Button("Show voice trace", systemImage: "list.bullet.rectangle") { expanded = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    VoiceButton(voice: voice)
                }
                .padding(6)
            }
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: !expanded)
    }

    private var collapse: some View {
        Button("Hide voice trace", systemImage: "chevron.up") { expanded = false }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.top, -2)
            .padding(.trailing, 44)
            .padding(12)
    }

    /// The last request and how it ended, in a line or two.
    private func latest(_ turn: VoiceControl.Turn) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(turn.transcript.isEmpty ? "…" : turn.transcript)
                .font(.callout.weight(.medium))
            if let error = turn.error {
                Text(error).foregroundStyle(.red)
            } else if !turn.steps.isEmpty {
                Text(turn.steps.map { $0.command?.summary ?? "?" }.joined(separator: ", "))
                    .foregroundStyle(turn.steps.allSatisfy { $0.result?.ok != false } ? Color.secondary : .red)
            }
        }
        .font(.caption)
        .lineLimit(2)
        .frame(maxWidth: 240, alignment: .trailing)
    }
}
