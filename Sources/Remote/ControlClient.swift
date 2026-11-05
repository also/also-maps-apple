import Foundation
import Network
import Observation

/// Finds Also Maps hosts on the local network.
@MainActor
@Observable
final class ControlBrowser {
    struct Peer: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let platform: String?
        let endpoint: NWEndpoint
    }

    private(set) var peers: [Peer] = []
    private(set) var status = "Not looking"
    private(set) var isBrowsing = false
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        stop()
        isBrowsing = true
        status = "Looking for Also Maps…"
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ControlTransport.serviceType, domain: nil),
                                using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                self.peers = results.compactMap(Self.makePeer).sorted { $0.name < $1.name }
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                switch state {
                case .ready:
                    self.status = "Looking for Also Maps…"
                case let .failed(error):
                    self.stop()
                    self.status = "Discovery failed: \(error.localizedDescription)"
                case let .waiting(error):
                    self.status = "Discovery waiting: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        peers = []
        status = "Not looking"
    }

    /// The first peer whose name is `name`, or contains it, ignoring case.
    func peer(matching name: String) -> Peer? {
        peers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? peers.first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    private static func makePeer(_ result: NWBrowser.Result) -> Peer? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        var platform: String?
        if case let .bonjour(record) = result.metadata { platform = record["platform"] }
        return Peer(name: name, platform: platform, endpoint: result.endpoint)
    }
}

/// A client's end of remote control: one host at a time, paired with its
/// code. Requests get answers, the host's events arrive in `onEvent`, and
/// (for the iPhone joystick) `controls` is streamed while connected.
///
/// Once a code has worked, a dropped connection is retried with backoff
/// until `disconnect`, so a long-lived client (the MCP server) rides out
/// Wi-Fi blips and the app restarting.
@MainActor
@Observable
final class ControlClient {
    enum Phase: Equatable { case idle, connecting, connected, reconnecting }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private(set) var phase = Phase.idle
    private(set) var status = "Not connected"
    /// The host's hello, once connected.
    private(set) var host: ControlHello?
    /// The joystick, streamed to the host while connected if `sendsInput`.
    var controls = RemoteControlState()

    var isConnected: Bool { phase == .connected }
    var isConnecting: Bool { phase == .connecting || phase == .reconnecting }

    @ObservationIgnored var onEvent: (@MainActor (String, JSONValue?) -> Void)?
    @ObservationIgnored var onConnect: (@MainActor (ControlHello) -> Void)?

    private let hello: ControlHello
    private let sendsInput: Bool
    private let timing: ControlTransport.Timing
    @ObservationIgnored private var target: (endpoint: NWEndpoint, code: String)?
    @ObservationIgnored private var connection: ControlConnection?
    @ObservationIgnored private var hasPaired = false
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var connectWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var inputLoop: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryDelay = Duration.milliseconds(500)
    @ObservationIgnored private var awaitingAck = false
    @ObservationIgnored private var lastSentControls = RemoteControlState()

    /// `kind`: "phone", "cli" or "mcp". `wantsEvents`: ask the host for its
    /// events. `sendsInput`: stream `controls`.
    init(name: String, kind: String, wantsEvents: Bool, sendsInput: Bool = false,
         timing: ControlTransport.Timing = .standard) {
        hello = ControlHello(name: name, kind: kind, wants: wantsEvents ? ["events"] : [])
        self.sendsInput = sendsInput
        self.timing = timing
    }

    // MARK: Connecting

    func connect(to endpoint: NWEndpoint, code: String) {
        let digits = code.filter { $0.isASCII && $0.isNumber }
        guard ControlTransport.isValidCode(digits) else {
            status = "Enter the 6-digit code the map shows"
            return
        }
        disconnect()
        target = (endpoint, digits)
        hasPaired = false
        retryDelay = .milliseconds(500)
        open(reconnecting: false)
    }

    /// Ends the connection and stops retrying.
    func disconnect() {
        retry?.cancel()
        retry = nil
        target = nil
        tearDown(reason: "Disconnected")
        phase = .idle
        status = "Not connected"
        failConnectWaiters("Disconnected")
    }

    /// Returns once connected, or throws if connecting fails for good or
    /// takes longer than `timeout`.
    func waitUntilConnected(timeout: Duration = .seconds(15)) async throws {
        if isConnected { return }
        guard phase != .idle else { throw Failure(status) }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.connectWaiters.removeValue(forKey: id)?.resume(throwing: Failure("Timed out connecting: \(self?.status ?? "")"))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            connectWaiters[id] = continuation
        }
    }

    private func open(reconnecting: Bool) {
        guard let target else { return }
        phase = reconnecting ? .reconnecting : .connecting
        status = reconnecting ? "Reconnecting…" : "Connecting…"
        let connection = ControlConnection(NWConnection(to: target.endpoint, using: ControlTransport.parameters(code: target.code)),
                                           receiveLimit: ControlMessage.hostFrameLimit,
                                           sendLimit: ControlMessage.clientFrameLimit, timing: timing)
        self.connection = connection
        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection else { return }
            connection.send(ControlMessage(type: .hello, hello: self.hello))
        }
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection, self.connection === connection else { return }
            self.handle(message)
        }
        connection.onClose = { [weak self, weak connection] reason in
            guard let self, let connection, self.connection === connection else { return }
            self.connectionEnded(reason)
        }
        connection.start()
    }

    private func connectionEnded(_ reason: String) {
        tearDown(reason: reason)
        guard target != nil, hasPaired else {
            // The first attempt failed: likely the wrong code or host.
            target = nil
            phase = .idle
            status = reason
            failConnectWaiters(reason)
            return
        }
        phase = .reconnecting
        status = "\(reason). Reconnecting…"
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(8))
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.target != nil, self.connection == nil else { return }
            self.open(reconnecting: true)
        }
    }

    private func tearDown(reason: String) {
        inputLoop?.cancel()
        inputLoop = nil
        connection?.close()
        connection = nil
        host = nil
        awaitingAck = false
        lastSentControls = RemoteControlState()
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: Failure("Connection lost before the answer: \(reason)"))
        }
    }

    private func failConnectWaiters(_ reason: String) {
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(throwing: Failure(reason)) }
    }

    // MARK: Messages

    private func handle(_ message: ControlMessage) {
        switch message.type {
        case .hello:
            guard host == nil, let hello = message.hello else { return }
            host = hello
            hasPaired = true
            retryDelay = .milliseconds(500)
            phase = .connected
            status = "Connected to \(hello.name)"
            let waiters = connectWaiters
            connectWaiters.removeAll()
            for waiter in waiters.values { waiter.resume() }
            if sendsInput { startInputLoop() }
            onConnect?(hello)
        case .inputAck:
            awaitingAck = false
        case .response:
            guard let id = message.id, let continuation = pending.removeValue(forKey: id) else { return }
            if message.ok == true {
                continuation.resume(returning: message.result ?? .null)
            } else {
                continuation.resume(throwing: Failure(message.error ?? "Failed"))
            }
        case .event:
            if let name = message.event { onEvent?(name, message.data) }
        case .ping, .input, .action, .request:
            break
        }
    }

    // MARK: Requests

    /// Calls `method` on the host. Waits for a connection first if one is
    /// being made.
    func request(_ method: String, _ params: JSONValue? = nil, timeout: Duration = .seconds(120)) async throws -> JSONValue {
        if !isConnected { try await waitUntilConnected() }
        guard let connection else { throw Failure("Not connected") }
        let id = nextID
        nextID += 1
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.pending.removeValue(forKey: id)?.resume(throwing: Failure("No answer to \(method) in time"))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            connection.send(.request(id: id, method: method, params: params))
        }
    }

    /// A button press: a `MapInput.Action` raw value.
    func sendAction(_ action: String) {
        guard isConnected else { return }
        connection?.send(ControlMessage(type: .action, action: action))
    }

    // MARK: Joystick

    /// About 60 snapshots a second while the sticks are off centre, one
    /// awaiting acknowledgement at a time so a slow network doesn't build a
    /// backlog. A late acknowledgement only delays the next snapshot.
    private func startInputLoop() {
        inputLoop?.cancel()
        inputLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.isConnected, let connection = self.connection else { return }
                let controls = self.controls
                guard !self.awaitingAck, !controls.isZero || controls != self.lastSentControls else { continue }
                self.awaitingAck = true
                self.lastSentControls = controls
                connection.send(ControlMessage(type: .input, input: controls))
            }
        }
    }
}

/// Codes that worked, by host name, so a client can reconnect after
/// relaunching without asking again.
enum ControlCodeBook {
    private static let key = "RemoteControl.codes"

    static func code(for host: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[host]
    }

    static func remember(_ code: String, for host: String, defaults: UserDefaults = .standard) {
        var codes = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        codes[host] = code
        defaults.set(codes, forKey: key)
    }
}
