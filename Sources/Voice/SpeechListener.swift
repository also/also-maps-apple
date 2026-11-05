@preconcurrency import AVFoundation
import Foundation
import Speech

/// The microphone through on-device speech recognition (SpeechAnalyzer and
/// SpeechTranscriber): start, receive text as it's recognised, stop to get
/// the rest. One utterance at a time.
@MainActor
final class SpeechListener {
    enum Event {
        /// Recognised so far and may still change.
        case volatile(String)
        /// A settled stretch of speech.
        case final(String)
    }

    enum Failure: LocalizedError {
        case microphoneDenied
        case unsupportedLocale(String)
        case noAudioFormat
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access is off for Also Maps"
            case let .unsupportedLocale(locale): "Speech recognition doesn’t support \(locale)"
            case .noAudioFormat: "No audio format for speech recognition"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private(set) var locale: Locale?

    var isRunning: Bool { analyzer != nil }

    /// Starts listening. `contextualStrings` bias recognition toward words
    /// the app expects (place names). Events arrive on the main actor;
    /// `onFinish` runs once recognition has delivered everything.
    func start(contextualStrings: [String], onEvent: @escaping (Event) -> Void,
               onFinish: @escaping (Error?) -> Void) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }

        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale else { throw Failure.unsupportedLocale(Locale.current.identifier) }
        self.locale = locale
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        #if !os(macOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
        try audioSession.setActive(true)
        #endif

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw Failure.noAudioFormat }
        try await analyzer.prepareToAnalyze(in: format)
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        input = continuation

        resultsTask = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    onEvent(result.isFinal ? .final(text) : .volatile(text))
                }
                onFinish(nil)
            } catch {
                onFinish(error)
            }
        }
        try await analyzer.start(inputSequence: stream)

        let node = engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        let converter = BufferConverter(from: micFormat, to: format)
        node.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            if let converted = converter.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops the microphone and finishes recognising what was heard.
    func stop() async {
        guard let analyzer else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        input?.finish()
        input = nil
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        self.analyzer = nil
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Abandons the utterance.
    func cancel() async {
        resultsTask?.cancel()
        await stop()
    }
}

/// Converts microphone buffers to the analyzer's format, on the audio
/// thread.
private final class BufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let output: AVAudioFormat

    init(from input: AVAudioFormat, to output: AVAudioFormat) {
        self.output = output
        converter = input == output ? nil : AVAudioConverter(from: input, to: output)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && converted.frameLength > 0 ? converted : nil
    }
}
