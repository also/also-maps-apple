import Network
import XCTest

/// Real loopback TLS/Bonjour tests, using the same transport as both apps.
@MainActor
final class RemoteControlSessionTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool, seconds: Double = 5) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Timed out waiting for local controller connection")
        if !condition() { throw TestError.timeout }
    }
    private enum TestError: Error { case timeout }

    private func discover(_ host: RemoteControlSession, _ phone: RemoteControlSession) async throws -> NWBrowser.Result {
        host.startHosting()
        phone.browse()
        try await waitUntil { phone.peers.contains { RemoteControlSession.name(of: $0) == host.hostName } }
        return try XCTUnwrap(phone.peers.first { RemoteControlSession.name(of: $0) == host.hostName })
    }

    func testPairDeliverActionsDisconnectAndReconnect() async throws {
        let host = RemoteControlSession(role: .host)
        let phone = RemoteControlSession(role: .controller)
        defer { phone.stop(); host.stop() }
        let peer = try await discover(host, phone)
        phone.connect(to: peer, code: host.pairingCode)
        try await waitUntil { host.isConnected && phone.isConnected }
        phone.controls = RemoteControlState(x: 0.75, y: -0.25, turn: 0.5, climb: -0.5, zoom: 1, fast: true)
        phone.sendAction(.toggleFly)
        phone.sendAction(.toggleFly)
        try await waitUntil { host.input.move.x == 0.75 }
        XCTAssertEqual(host.input.altitude, -0.5)
        XCTAssertEqual(host.input.zoom, 1)
        XCTAssertTrue(host.input.fast)
        // Two short taps are two commands, even within one rendering frame.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.takeActions(), [.toggleFly, .toggleFly])
        XCTAssertTrue(host.takeActions().isEmpty)
        phone.disconnect()
        try await waitUntil { !host.isConnected }
        XCTAssertEqual(host.input.move, .zero)
        XCTAssertFalse(host.input.fast)
        phone.connect(to: peer, code: host.pairingCode)
        try await waitUntil { host.isConnected && phone.isConnected }
        XCTAssertEqual(host.input.move, .zero)
    }

    func testWrongCodeCannotPair() async throws {
        let host = RemoteControlSession(role: .host)
        let phone = RemoteControlSession(role: .controller)
        defer { phone.stop(); host.stop() }
        let peer = try await discover(host, phone)
        let wrongCode = host.pairingCode == "000000000000" ? "111111111111" : "000000000000"
        phone.connect(to: peer, code: wrongCode)
        try await waitUntil({ !phone.isConnecting }, seconds: 12)
        XCTAssertFalse(host.isConnected)
        XCTAssertFalse(phone.isConnected)
        XCTAssertEqual(host.input.move, .zero)
    }

    func testStalledInputExpiresAndDelayedStateCannotRestartMotion() async throws {
        let host = RemoteControlSession(role: .host)
        let browser = RemoteControlSession(role: .controller)
        defer { browser.stop(); host.stop() }
        let peer = try await discover(host, browser)
        let raw = NWConnection(to: peer.endpoint, using: RemoteControlSession.parameters(code: host.pairingCode))
        defer { raw.cancel() }
        raw.start(queue: .main)
        // NWConnection queues these until the TLS handshake completes.
        raw.send(content: try RemoteControlMessage(kind: .hello).framed(), completion: .contentProcessed { _ in })
        let state = try RemoteControlMessage(kind: .state, state: RemoteControlState(x: 1)).framed()
        raw.send(content: state, completion: .contentProcessed { _ in })
        try await waitUntil { host.input.move.x == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(host.input.move, .zero)
        raw.send(content: state, completion: .contentProcessed { _ in })
        try await waitUntil { !host.isConnected }
        XCTAssertEqual(host.input.move, .zero)
    }
}
