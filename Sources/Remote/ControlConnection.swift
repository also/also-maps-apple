import CryptoKit
import Foundation
import Network

/// The transport both ends share: Bonjour service type, TLS from the
/// pairing code, and liveness timing.
enum ControlTransport {
    static let serviceType = "_alsomaps-rc._tcp"

    /// How long each end waits. Liveness is separate from joystick input:
    /// an idle connection (an agent waiting between commands) stays up as
    /// long as pings arrive.
    struct Timing: Sendable {
        /// Send a ping when nothing else has been sent for this long.
        var pingInterval: Duration = .seconds(1)
        /// Close a connection when nothing has arrived for this long.
        var silenceLimit: Duration = .seconds(6)
        /// Close a connection that hasn't become ready (TLS, a wrong code)
        /// in this long.
        var handshakeLimit: Duration = .seconds(10)
        /// The host zeroes a controller's sticks when its snapshots stop for
        /// this long. It doesn't disconnect.
        var inputExpiry: Duration = .milliseconds(250)

        static let standard = Timing()
    }

    /// The code is never advertised. TLS authenticates peers with a key
    /// derived from the displayed code; no certificates. This isn't a PAKE:
    /// someone on the network who can try many codes could find it.
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
        // The OS notices a peer that vanished (Wi-Fi off) even if neither
        // side's timers run, e.g. while suspended.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Six random digits.
    static func newCode() -> String {
        String(format: "%06u", UInt32.random(in: 0...999_999))
    }

    static func isValidCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// One framed, TLS-protected connection, from either end: reads and writes
/// messages, sends pings when idle, and closes on silence, a network error
/// or a malformed frame. Callbacks run on the main actor.
@MainActor
final class ControlConnection {
    let id = UUID()
    let connection: NWConnection
    /// Called once, when TLS is up.
    var onReady: (@MainActor () -> Void)?
    var onMessage: (@MainActor (ControlMessage) -> Void)?
    /// Called once, with why. Not called for `close` from this end.
    var onClose: (@MainActor (String) -> Void)?
    private(set) var isReady = false
    private(set) var isClosed = false

    private let receiveLimit: Int
    private let sendLimit: Int
    private let timing: ControlTransport.Timing
    private var lastReceived = ContinuousClock.now
    private var lastSent = ContinuousClock.now
    private var watchdog: Task<Void, Never>?

    /// `receiveLimit`: the largest frame accepted from the peer, so a host
    /// passes `ControlMessage.clientFrameLimit`.
    init(_ connection: NWConnection, receiveLimit: Int, sendLimit: Int,
         timing: ControlTransport.Timing = .standard) {
        self.connection = connection
        self.receiveLimit = receiveLimit
        self.sendLimit = sendLimit
        self.timing = timing
    }

    func start() {
        let started = ContinuousClock.now
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                switch state {
                case .ready:
                    guard !self.isReady else { return }
                    self.isReady = true
                    self.lastReceived = .now
                    self.receiveHeader()
                    self.onReady?()
                case let .failed(error):
                    self.finish("Connection failed: \(Self.describe(error))")
                case let .waiting(error):
                    // TLS failures (a wrong code) can show up as waiting.
                    if case .tls = error { self.finish("Couldn't pair: \(Self.describe(error))") }
                case .cancelled:
                    self.finish("Connection closed")
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !self.isClosed else { return }
                let now = ContinuousClock.now
                if !self.isReady {
                    if now - started > self.timing.handshakeLimit {
                        self.finish("Timed out connecting. Check the code and that both devices are on the same network.")
                    }
                    continue
                }
                if now - self.lastReceived > self.timing.silenceLimit {
                    self.finish("The other end stopped responding")
                    return
                }
                if now - self.lastSent >= self.timing.pingInterval {
                    self.send(ControlMessage(type: .ping))
                }
            }
        }
    }

    func send(_ message: ControlMessage) {
        guard !isClosed else { return }
        let frame: Data
        do {
            frame = try message.framed(limit: sendLimit)
        } catch {
            // Too big to send: answer a request with an error instead.
            if message.type == .response, let id = message.id {
                send(.failure(id: id, error: "Response too large to send"))
            }
            return
        }
        lastSent = .now
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, let error else { return }
                self.finish("Send failed: \(Self.describe(error))")
            }
        })
    }

    /// Closes from this end, without calling `onClose`.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        watchdog?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func finish(_ reason: String) {
        guard !isClosed else { return }
        close()
        onClose?(reason)
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let error { self.finish("Receive failed: \(Self.describe(error))"); return }
                guard let data, !data.isEmpty else {
                    self.finish(complete ? "The other end closed the connection" : "Receive failed")
                    return
                }
                guard let size = try? ControlMessage.bodySize(data, limit: self.receiveLimit) else {
                    self.finish("Malformed frame")
                    return
                }
                self.receiveBody(size: size)
            }
        }
    }

    private func receiveBody(size: Int) {
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let error { self.finish("Receive failed: \(Self.describe(error))"); return }
                guard let data, data.count == size else {
                    self.finish(complete ? "The other end closed the connection" : "Truncated frame")
                    return
                }
                let message: ControlMessage
                do {
                    message = try ControlMessage.decode(data)
                } catch ControlMessage.ProtocolError.unsupportedVersion(let version) {
                    self.finish("The other end speaks protocol version \(version), not \(ControlMessage.version). Update both apps.")
                    return
                } catch {
                    self.finish("Malformed message")
                    return
                }
                self.lastReceived = .now
                self.onMessage?(message)
                if !self.isClosed { self.receiveHeader() }
            }
        }
    }

    private static func describe(_ error: NWError) -> String {
        if case let .tls(status) = error {
            return "TLS error \(status); is the pairing code right?"
        }
        return error.localizedDescription
    }
}
