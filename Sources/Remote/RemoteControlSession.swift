import CryptoKit
import Foundation
import Network
import Observation
import Security

/// One foreground-only controller session. Network callbacks run on main;
/// the map samples the latest input at its own frame rate.
@MainActor
@Observable
final class RemoteControlSession {
    enum Role { case host, controller }
    static let serviceType = "_alsomaps-rc._tcp"
    let role: Role
    private(set) var status = "Not connected"
    private(set) var isEnabled = false
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var pairingCode = ""
    private(set) var hostName = ""
    private(set) var peers: [NWBrowser.Result] = []
    var controls = RemoteControlState()

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var received = RemoteControlState()
    @ObservationIgnored private var lastInput = ContinuousClock.now
    @ObservationIgnored private var lastAcknowledgement = ContinuousClock.now
    @ObservationIgnored private var awaitingAcknowledgement = false
    @ObservationIgnored private var actions: [MapInput.Action] = []

    init(role: Role) { self.role = role }

    var input: MapInput {
        guard isConnected, ContinuousClock.now - lastInput < .milliseconds(250) else { return MapInput() }
        var input = MapInput()
        input.move = SIMD2(received.x, received.y)
        input.turn = received.turn
        input.altitude = received.climb
        input.zoom = received.zoom
        input.fast = received.fast
        return input
    }

    func takeActions() -> [MapInput.Action] {
        defer { actions.removeAll() }
        guard isConnected, ContinuousClock.now - lastInput < .milliseconds(250) else { return [] }
        return actions
    }

    func startHosting() {
        stop()
        guard role == .host else { return }
        pairingCode = String(format: "%06u", UInt32.random(in: 0...999_999))
        hostName = "Also Maps \(Int.random(in: 1000...9999))"
        do {
            let listener = try NWListener(using: Self.parameters(code: pairingCode))
            self.listener = listener
            isEnabled = true
            status = "Starting…"
            listener.service = NWListener.Service(name: hostName, type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: if self.connection == nil { self.status = "Ready to pair" }
                    case .failed(let error): self.stop(); self.status = "Cannot host: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] candidate in
                MainActor.assumeIsolated {
                    guard let self, self.isEnabled, self.connection == nil else { candidate.cancel(); return }
                    self.accept(candidate)
                }
            }
            listener.start(queue: .main)
        } catch { status = "Cannot host: \(error.localizedDescription)" }
    }

    func browse() {
        stop()
        guard role == .controller else { return }
        isEnabled = true
        status = "Looking for Vision Pro…"
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                self.peers = results.sorted { Self.name(of: $0) < Self.name(of: $1) }
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                if case .failed(let error) = state {
                    self.stop(); self.status = "Discovery failed: \(error.localizedDescription)"
                }
            }
        }
        browser.start(queue: .main)
    }

    static func name(of peer: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = peer.endpoint { return name }
        return "Also Maps"
    }

    func connect(to peer: NWBrowser.Result, code: String) {
        guard role == .controller else { return }
        let digits = code.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 6 else { status = "Enter the 6-digit code shown on Vision Pro"; return }
        disconnect()
        accept(NWConnection(to: peer.endpoint, using: Self.parameters(code: digits)))
    }

    func sendAction(_ action: MapInput.Action) {
        guard role == .controller, isConnected, let connection else { return }
        send(RemoteControlMessage(kind: .action, action: action.rawValue), on: connection)
    }

    func stop() {
        isEnabled = false
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        peers = []
        disconnect()
        pairingCode = ""
        status = "Not connected"
    }

    func disconnect() {
        let old = connection
        connection = nil
        old?.cancel()
        loop?.cancel(); loop = nil
        isConnected = false
        isConnecting = false
        awaitingAcknowledgement = false
        controls = RemoteControlState()
        received = RemoteControlState()
        actions.removeAll()
        status = role == .host && isEnabled ? "Ready to pair" : "Not connected"
    }

    private func accept(_ candidate: NWConnection) {
        connection = candidate
        isConnecting = true
        status = "Connecting…"
        lastAcknowledgement = .now
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            MainActor.assumeIsolated {
                guard let self, let candidate, self.connection === candidate else { return }
                switch state {
                case .ready:
                    self.send(RemoteControlMessage(kind: .hello), on: candidate)
                    self.receiveHeader(on: candidate)
                case .failed, .cancelled:
                    self.disconnect()
                    self.status = "Disconnected. Check the code and try again."
                default: break
                }
            }
        }
        candidate.start(queue: .main)
        // Covers stalled discovery/TLS handshakes as well as stalled input.
        loop = Task { [weak self, weak candidate] in
            let started = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self, let candidate, self.connection === candidate else { return }
                if !self.isConnected {
                    if ContinuousClock.now - started > .seconds(10) {
                        self.disconnect(); self.status = "Connection timed out. Check the code and try again."
                    }
                    continue
                }
                if self.role == .controller {
                    if self.awaitingAcknowledgement {
                        if ContinuousClock.now - self.lastAcknowledgement > .milliseconds(500) {
                            self.disconnect(); self.status = "Connection stalled. Reconnect to continue."
                        }
                    } else {
                        self.awaitingAcknowledgement = true
                        self.lastAcknowledgement = .now
                        self.send(RemoteControlMessage(kind: .state, state: self.controls), on: candidate)
                    }
                } else if ContinuousClock.now - self.lastInput > .seconds(1) {
                    self.disconnect(); self.status = "Controller stopped sending. Ready to pair again."
                }
            }
        }
    }

    private func receiveHeader(on candidate: NWConnection) {
        candidate.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak candidate] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, let candidate, self.connection === candidate else { return }
                guard error == nil, let data, let size = try? RemoteControlMessage.bodySize(data) else {
                    self.disconnect(); return
                }
                self.receiveBody(size: size, on: candidate)
            }
        }
    }

    private func receiveBody(size: Int, on candidate: NWConnection) {
        candidate.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self, weak candidate] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, let candidate, self.connection === candidate else { return }
                guard error == nil, let data, data.count == size,
                      let message = try? JSONDecoder().decode(RemoteControlMessage.self, from: data),
                      message.version == RemoteControlMessage.version else { self.disconnect(); return }
                self.handle(message, on: candidate)
                if self.connection === candidate { self.receiveHeader(on: candidate) }
            }
        }
    }

    private func handle(_ message: RemoteControlMessage, on candidate: NWConnection) {
        if message.kind == .hello {
            guard !isConnected else { disconnect(); return }
            isConnected = true
            isConnecting = false
            lastInput = .now
            status = "Connected"
            return
        }
        guard isConnected else { disconnect(); return }
        switch message.kind {
        case .state:
            guard role == .host, let state = message.state, state.isValid,
                  ContinuousClock.now - lastInput < .milliseconds(250) else { disconnect(); return }
            received = state
            lastInput = .now
            send(RemoteControlMessage(kind: .acknowledgement), on: candidate)
        case .action:
            guard role == .host, let raw = message.action, let action = MapInput.Action(rawValue: raw),
                  actions.count < 32 else { disconnect(); return }
            actions.append(action)
        case .acknowledgement:
            guard role == .controller else { disconnect(); return }
            awaitingAcknowledgement = false
        case .hello: break
        }
    }

    private func send(_ message: RemoteControlMessage, on candidate: NWConnection) {
        guard let data = try? message.framed() else { disconnect(); return }
        candidate.send(content: data, completion: .contentProcessed { [weak self, weak candidate] error in
            MainActor.assumeIsolated {
                guard let self, let candidate, self.connection === candidate, error != nil else { return }
                self.disconnect()
            }
        })
    }

    /// The code is never advertised. TLS authenticates peers with a fresh PSK
    /// derived from the displayed code; no server or certificate exception.
    static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                                        salt: Data("AlsoMaps-Remote-v1".utf8), info: Data(), outputByteCount: 32)
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) as __DispatchData }
        let identity = Data("AlsoMaps-Remote-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) as __DispatchData }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret, identity)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}
