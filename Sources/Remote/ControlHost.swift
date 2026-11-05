import Foundation
import Network
import Observation

/// The app's end of remote control: advertises itself over Bonjour, accepts
/// a few paired clients at once (the iPhone joystick, the CLI, an MCP
/// server), merges their joystick input, queues their button presses, runs
/// their requests through `handler` and sends them events. See
/// docs/remote-control.md.
///
/// The pairing code is kept between launches (when `defaults` is given), so
/// a client that paired once can reconnect after either end restarts.
@MainActor
@Observable
final class ControlHost {
    struct Client: Identifiable, Equatable {
        let id: UUID
        var name: String
        var kind: String
        let since: Date
    }

    struct Request {
        let client: Client
        let method: String
        let params: JSONValue?
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    typealias Handler = @MainActor (Request) async throws -> JSONValue

    private(set) var isEnabled = false
    private(set) var status = "Off"
    private(set) var pairingCode: String
    /// The Bonjour name, as registered (the system renames on a clash).
    private(set) var hostName: String
    private(set) var port: UInt16?
    private(set) var clients: [Client] = []
    /// Recent requests, newest first, for the host's panel.
    private(set) var log: [String] = []

    let platform: String
    /// What the hello advertises; the handler decides what actually works.
    @ObservationIgnored var methods: [String] = []
    @ObservationIgnored var eventNames: [String] = []
    @ObservationIgnored var handler: Handler?
    /// Debug Mac builds: where to write the name, port and code, so a CLI on
    /// the same Mac can connect without anyone typing the code.
    @ObservationIgnored var localFile: URL?

    private let timing: ControlTransport.Timing
    private let defaults: UserDefaults?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var peers: [UUID: Peer] = [:]
    @ObservationIgnored private var actions: [MapInput.Action] = []
    @ObservationIgnored private var reopen: Task<Void, Never>?

    static let maximumClients = 4
    private static let maximumQueuedRequests = 64
    private static let maximumQueuedActions = 32
    private static let keptLogLines = 40
    private static let enabledKey = "RemoteControl.enabled"
    private static let codeKey = "RemoteControl.code"
    private static let portKey = "RemoteControl.port"

    private final class Peer {
        let connection: ControlConnection
        var hello: ControlHello?
        var client: Client?
        var input = RemoteControlState()
        var lastInput: ContinuousClock.Instant?
        var wantsEvents = false
        var queue: [ControlMessage] = []
        var isAnswering = false

        init(_ connection: ControlConnection) { self.connection = connection }
    }

    init(platform: String, name: String, defaults: UserDefaults? = .standard, timing: ControlTransport.Timing = .standard) {
        self.platform = platform
        self.hostName = name
        self.defaults = defaults
        self.timing = timing
        if let saved = defaults?.string(forKey: Self.codeKey), ControlTransport.isValidCode(saved) {
            pairingCode = saved
        } else {
            pairingCode = ControlTransport.newCode()
            defaults?.set(pairingCode, forKey: Self.codeKey)
        }
    }

    /// Whether remote control was left on, last time.
    var wasEnabled: Bool { defaults?.bool(forKey: Self.enabledKey) ?? false }

    // MARK: On and off

    func start() {
        isEnabled = true
        defaults?.set(true, forKey: Self.enabledKey)
        openListener()
    }

    func stop() {
        isEnabled = false
        defaults?.set(false, forKey: Self.enabledKey)
        closeEverything()
        status = "Off"
        removeLocalFile()
    }

    /// The app is going to the background: drop the listener and clients,
    /// but stay enabled with the same code, to come back on `resume`.
    func suspend() {
        guard isEnabled else { return }
        closeEverything()
        status = "Paused while in the background"
    }

    func resume() {
        guard isEnabled, listener == nil else { return }
        openListener()
    }

    /// A new code: clients paired with the old one are disconnected.
    func newCode() {
        pairingCode = ControlTransport.newCode()
        defaults?.set(pairingCode, forKey: Self.codeKey)
        guard isEnabled else { return }
        closeEverything()
        openListener()
    }

    func disconnect(_ client: Client) {
        guard let peer = peers[client.id] else { return }
        peer.connection.close()
        dropPeer(client.id)
    }

    // MARK: What the map reads

    /// Every controller's sticks, from snapshots recent enough to trust.
    var input: MapInput {
        var merged = MapInput()
        let now = ContinuousClock.now
        for peer in peers.values {
            guard let last = peer.lastInput, now - last < timing.inputExpiry else { continue }
            var input = MapInput()
            input.move = SIMD2(peer.input.x, peer.input.y)
            input.turn = peer.input.turn
            input.altitude = peer.input.climb
            input.zoom = peer.input.zoom
            input.fast = peer.input.fast
            merged.merge(input)
        }
        return merged
    }

    /// Button presses since the last call, in order.
    func takeActions() -> [MapInput.Action] {
        defer { actions.removeAll() }
        return actions
    }

    /// Sends an event to every client that asked for events.
    func broadcast(_ name: String, _ data: JSONValue? = nil) {
        let message = ControlMessage.event(name, data: data)
        for peer in peers.values where peer.wantsEvents && peer.hello != nil {
            peer.connection.send(message)
        }
    }

    /// Queues a press as if a controller sent it.
    func enqueue(_ action: MapInput.Action) {
        guard actions.count < Self.maximumQueuedActions else { return }
        actions.append(action)
    }

    // MARK: Listening

    private func openListener() {
        guard listener == nil else { return }
        reopen?.cancel()
        // The last port again, if it's free, so a client that connected by
        // port (the CLI on this Mac) can reconnect after the app restarts.
        let savedPort = (defaults?.integer(forKey: Self.portKey)).flatMap { UInt16(exactly: $0) }
            .flatMap { $0 == 0 ? nil : NWEndpoint.Port(rawValue: $0) }
        let listener: NWListener
        do {
            if let savedPort {
                listener = try NWListener(using: ControlTransport.parameters(code: pairingCode), on: savedPort)
            } else {
                listener = try NWListener(using: ControlTransport.parameters(code: pairingCode))
            }
        } catch {
            if savedPort != nil {
                defaults?.removeObject(forKey: Self.portKey)
                openListener()
                return
            }
            status = "Can't listen: \(error.localizedDescription)"
            scheduleReopen()
            return
        }
        self.listener = listener
        status = "Starting…"
        listener.service = NWListener.Service(name: hostName, type: ControlTransport.serviceType, domain: nil,
                                              txtRecord: NWTXTRecord(["platform": platform,
                                                                      "v": String(ControlMessage.version)]))
        listener.serviceRegistrationUpdateHandler = { [weak self, weak listener] change in
            MainActor.assumeIsolated {
                guard let self, self.listener === listener else { return }
                if case let .add(endpoint) = change, case let .service(name, _, _, _) = endpoint {
                    self.hostName = name
                    self.writeLocalFile()
                }
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    if let port = self.port { self.defaults?.set(Int(port), forKey: Self.portKey) }
                    self.updateStatus()
                    self.writeLocalFile()
                case let .failed(error):
                    self.listener = nil
                    listener.cancel()
                    if savedPort != nil {
                        // Taken by something else: any port will do.
                        self.defaults?.removeObject(forKey: Self.portKey)
                        self.openListener()
                        return
                    }
                    self.status = "Can't listen: \(error.localizedDescription)"
                    self.scheduleReopen()
                case let .waiting(error):
                    self.status = "Waiting for the network: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] candidate in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled, self.peers.count < Self.maximumClients else {
                    candidate.cancel()
                    return
                }
                self.accept(candidate)
            }
        }
        listener.start(queue: .main)
    }

    private func scheduleReopen() {
        reopen?.cancel()
        reopen = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.isEnabled, self.listener == nil else { return }
            self.openListener()
        }
    }

    private func closeEverything() {
        reopen?.cancel()
        listener?.cancel()
        listener = nil
        port = nil
        for peer in peers.values { peer.connection.close() }
        peers.removeAll()
        clients.removeAll()
        actions.removeAll()
    }

    private func accept(_ candidate: NWConnection) {
        let connection = ControlConnection(candidate, receiveLimit: ControlMessage.clientFrameLimit,
                                           sendLimit: ControlMessage.hostFrameLimit, timing: timing)
        let peer = Peer(connection)
        let id = connection.id
        peers[id] = peer
        connection.onMessage = { [weak self] message in self?.handle(message, from: id) }
        connection.onClose = { [weak self] reason in
            self?.dropPeer(id)
            #if DEBUG
            print("[AlsoMaps] remote control: client left: \(reason)")
            #endif
        }
        connection.start()
    }

    private func dropPeer(_ id: UUID) {
        peers[id] = nil
        clients.removeAll { $0.id == id }
        updateStatus()
    }

    private func updateStatus() {
        guard isEnabled, listener != nil else { return }
        status = clients.isEmpty ? "Ready to pair" : "\(clients.count) connected"
    }

    // MARK: Messages

    private func handle(_ message: ControlMessage, from id: UUID) {
        guard let peer = peers[id] else { return }
        if peer.hello == nil, message.type != .hello, message.type != .ping {
            // Nothing before hello.
            disconnectPeer(id)
            return
        }
        switch message.type {
        case .hello:
            guard peer.hello == nil, let hello = message.hello else { disconnectPeer(id); return }
            peer.hello = hello
            peer.wantsEvents = hello.wants?.contains("events") ?? false
            let client = Client(id: id, name: hello.name, kind: hello.kind, since: Date())
            peer.client = client
            clients.append(client)
            updateStatus()
            peer.connection.send(ControlMessage(type: .hello, hello: ControlHello(
                name: hostName, kind: "host", platform: platform, methods: methods, events: eventNames)))
        case .ping:
            break
        case .input:
            guard let input = message.input, input.isValid else { disconnectPeer(id); return }
            peer.input = input
            peer.lastInput = .now
            peer.connection.send(ControlMessage(type: .inputAck))
        case .action:
            guard let raw = message.action, let action = MapInput.Action(rawValue: raw) else { return }
            enqueue(action)
        case .request:
            guard let requestID = message.id else { return }
            guard peer.queue.count < Self.maximumQueuedRequests else {
                peer.connection.send(.failure(id: requestID, error: "Too many requests waiting"))
                return
            }
            peer.queue.append(message)
            answerNext(peer)
        case .inputAck, .response, .event:
            // A client's; ignore rather than fail, for later versions.
            break
        }
    }

    private func disconnectPeer(_ id: UUID) {
        peers[id]?.connection.close()
        dropPeer(id)
    }

    /// One request at a time per client, in the order sent, so "climb then
    /// turn" happens in that order.
    private func answerNext(_ peer: Peer) {
        guard !peer.isAnswering, !peer.queue.isEmpty, let client = peer.client else { return }
        peer.isAnswering = true
        let message = peer.queue.removeFirst()
        Task { [weak self] in
            let reply = await self?.answer(message, from: client) ?? .failure(id: message.id ?? 0, error: "Host stopped")
            peer.connection.send(reply)
            peer.isAnswering = false
            self?.answerNext(peer)
        }
    }

    private func answer(_ message: ControlMessage, from client: Client) async -> ControlMessage {
        let id = message.id ?? 0
        guard let method = message.method else { return .failure(id: id, error: "No method") }
        record("\(client.name): \(method) \(message.params?.jsonString ?? "")")
        guard let handler else { return .failure(id: id, error: "This map can't answer requests") }
        do {
            let result = try await handler(Request(client: client, method: method, params: message.params))
            return .response(id: id, result: result)
        } catch {
            return .failure(id: id, error: error.localizedDescription)
        }
    }

    private func record(_ line: String) {
        log.insert(line, at: 0)
        if log.count > Self.keptLogLines { log.removeLast() }
        #if DEBUG
        print("[AlsoMaps] remote control: \(line)")
        #endif
    }

    // MARK: Local file

    private func writeLocalFile() {
        guard let localFile, let port else { return }
        let info = ControlLocalInfo(name: hostName, port: port, code: pairingCode, platform: platform,
                             pid: ProcessInfo.processInfo.processIdentifier)
        do {
            try FileManager.default.createDirectory(at: localFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(info).write(to: localFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localFile.path)
        } catch {
            #if DEBUG
            print("[AlsoMaps] remote control: couldn't write \(localFile.path): \(error)")
            #endif
        }
    }

    private func removeLocalFile() {
        guard let localFile else { return }
        try? FileManager.default.removeItem(at: localFile)
    }
}
