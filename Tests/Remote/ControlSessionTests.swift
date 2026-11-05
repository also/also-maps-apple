import Network
import XCTest

/// Real TLS connections over loopback (and Bonjour, for reconnecting), the
/// same transport the apps and the CLI use. Timings are shortened so
/// liveness is exercised in seconds.
@MainActor
final class ControlSessionTests: XCTestCase {
    private let timing = ControlTransport.Timing(pingInterval: .milliseconds(200), silenceLimit: .seconds(1),
                                                 handshakeLimit: .seconds(5), inputExpiry: .milliseconds(250))
    private var hosts: [ControlHost] = []
    private var clients: [ControlClient] = []

    override func tearDown() async throws {
        for client in clients { client.disconnect() }
        for host in hosts { host.stop() }
        clients = []
        hosts = []
    }

    private enum TestError: Error { case timeout(String) }

    private func waitUntil(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else {
            XCTFail("Timed out waiting until \(what)")
            throw TestError.timeout(what)
        }
    }

    private func makeHost(handler: ControlHost.Handler? = nil) async throws -> ControlHost {
        let host = ControlHost(platform: "test", name: "Also Maps Test \(UUID().uuidString.prefix(8))",
                               defaults: nil, timing: timing)
        host.handler = handler
        hosts.append(host)
        host.start()
        try await waitUntil("the host listens") { host.port != nil }
        return host
    }

    private func loopback(_ host: ControlHost) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: host.port!)!)
    }

    private func makeClient(_ name: String = "client", wantsEvents: Bool = false, sendsInput: Bool = false) -> ControlClient {
        let client = ControlClient(name: name, kind: "test", wantsEvents: wantsEvents, sendsInput: sendsInput, timing: timing)
        clients.append(client)
        return client
    }

    private func connected(to host: ControlHost, _ client: ControlClient) async throws {
        client.connect(to: loopback(host), code: host.pairingCode)
        try await client.waitUntilConnected(timeout: .seconds(5))
    }

    // MARK: Pairing

    func testPairsAndExchangesHellos() async throws {
        let host = try await makeHost()
        host.methods = ["state.get"]
        let client = makeClient("Phone")
        try await connected(to: host, client)
        XCTAssertEqual(client.host?.platform, "test")
        XCTAssertEqual(client.host?.methods, ["state.get"])
        try await waitUntil("the host lists the client") { host.clients.map(\.name) == ["Phone"] }
    }

    func testWrongCodeCannotPair() async throws {
        let host = try await makeHost()
        let client = makeClient()
        client.connect(to: loopback(host), code: host.pairingCode == "000000" ? "111111" : "000000")
        do {
            try await client.waitUntilConnected(timeout: .seconds(8))
            XCTFail("Connected with the wrong code")
        } catch {}
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.phase, .idle, "A first attempt that fails isn't retried")
        XCTAssertTrue(host.clients.isEmpty)
    }

    func testANewCodeDisconnectsEveryone() async throws {
        let host = try await makeHost()
        let client = makeClient()
        try await connected(to: host, client)
        let old = host.pairingCode
        host.newCode()
        XCTAssertNotEqual(host.pairingCode, old)
        try await waitUntil("the client notices") { !client.isConnected }
        XCTAssertTrue(host.clients.isEmpty)
    }

    // MARK: Liveness

    func testIdleConnectionStaysUp() async throws {
        let host = try await makeHost()
        let client = makeClient()
        try await connected(to: host, client)
        // Several silence limits with nothing but pings.
        try await Task.sleep(for: .seconds(4))
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(host.clients.count, 1)
    }

    func testStaleInputZeroesTheSticksWithoutDisconnecting() async throws {
        let host = try await makeHost()
        // A controller that sends one snapshot and then goes quiet (but
        // keeps pinging), as if its app stalled.
        let raw = ControlConnection(NWConnection(to: loopback(host), using: ControlTransport.parameters(code: host.pairingCode)),
                                    receiveLimit: ControlMessage.hostFrameLimit, sendLimit: ControlMessage.clientFrameLimit,
                                    timing: timing)
        defer { raw.close() }
        raw.onReady = { [weak raw] in
            raw?.send(ControlMessage(type: .hello, hello: ControlHello(name: "raw", kind: "test")))
            raw?.send(ControlMessage(type: .input, input: RemoteControlState(x: 1)))
        }
        raw.start()
        try await waitUntil("the stick arrives") { host.input.move.x == 1 }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(host.input.move, .zero)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(host.clients.count, 1, "Stale input isn't a reason to disconnect")
        // A later snapshot is taken as new input.
        raw.send(ControlMessage(type: .input, input: RemoteControlState(y: -0.5)))
        try await waitUntil("the next stick arrives") { host.input.move.y == -0.5 }
    }

    func testASilentPeerIsDropped() async throws {
        let host = try await makeHost()
        // Hello, then nothing at all: its timer never pings.
        let quiet = ControlTransport.Timing(pingInterval: .seconds(60), silenceLimit: .seconds(60),
                                            handshakeLimit: .seconds(5), inputExpiry: .milliseconds(250))
        let raw = ControlConnection(NWConnection(to: loopback(host), using: ControlTransport.parameters(code: host.pairingCode)),
                                    receiveLimit: ControlMessage.hostFrameLimit, sendLimit: ControlMessage.clientFrameLimit,
                                    timing: quiet)
        defer { raw.close() }
        raw.onReady = { [weak raw] in
            raw?.send(ControlMessage(type: .hello, hello: ControlHello(name: "raw", kind: "test")))
        }
        raw.start()
        try await waitUntil("the host lists it") { host.clients.count == 1 }
        try await waitUntil("the host drops it", seconds: 4) { host.clients.isEmpty }
    }

    // MARK: Input and actions

    func testSticksAndActionsFromTwoControllersAtOnce() async throws {
        let host = try await makeHost()
        let left = makeClient("left", sendsInput: true)
        let right = makeClient("right", sendsInput: true)
        try await connected(to: host, left)
        try await connected(to: host, right)
        left.controls = RemoteControlState(x: 0.5)
        right.controls = RemoteControlState(climb: -0.5, fast: true)
        try await waitUntil("both sticks arrive") { host.input.move.x == 0.5 && host.input.altitude == -0.5 }
        XCTAssertTrue(host.input.fast)
        left.sendAction("toggleFly")
        left.sendAction("toggleFly")
        right.sendAction("faceNorth")
        right.sendAction("notAnAction")
        try await Task.sleep(for: .milliseconds(200))
        let actions = host.takeActions()
        XCTAssertEqual(actions.filter { $0 == .toggleFly }.count, 2, "Two taps are two presses")
        XCTAssertEqual(actions.filter { $0 == .faceNorth }.count, 1)
        XCTAssertTrue(host.takeActions().isEmpty)
        // Centring a stick is sent once, then nothing.
        left.controls = RemoteControlState()
        right.controls = RemoteControlState()
        try await waitUntil("the sticks centre") { host.input.move == .zero && host.input.altitude == 0 }
        XCTAssertEqual(host.clients.count, 2)
    }

    // MARK: Requests and events

    func testRequestsAreAnsweredInOrder() async throws {
        var order: [Double] = []
        let host = try await makeHost { request in
            let delay = request.params?["delay"]?.number ?? 0
            try await Task.sleep(for: .milliseconds(Int(delay)))
            order.append(delay)
            if request.method == "fail" { throw ControlHost.Failure("Failed on purpose") }
            return ["method": .string(request.method), "from": .string(request.client.name)]
        }
        let client = makeClient("agent")
        try await connected(to: host, client)
        async let slow = client.request("echo", ["delay": 300])
        async let fast = client.request("echo", ["delay": 0])
        let (first, second) = try await (slow, fast)
        XCTAssertEqual(first["from"]?.string, "agent")
        XCTAssertEqual(second["method"]?.string, "echo")
        XCTAssertEqual(order, [300, 0], "The second request waits for the first")
        do {
            _ = try await client.request("fail")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Failed on purpose")
        }
        XCTAssertFalse(host.log.isEmpty)
    }

    func testEventsGoOnlyToClientsThatAskedForThem() async throws {
        let host = try await makeHost()
        let listener = makeClient("listener", wantsEvents: true)
        let other = makeClient("other")
        var heard: [String] = []
        var otherHeard: [String] = []
        listener.onEvent = { name, _ in heard.append(name) }
        other.onEvent = { name, _ in otherHeard.append(name) }
        try await connected(to: host, listener)
        try await connected(to: host, other)
        try await waitUntil("both are listed") { host.clients.count == 2 }
        host.broadcast("camera", ["latitude": 1])
        host.broadcast("motion.finished")
        try await waitUntil("events arrive") { heard == ["camera", "motion.finished"] }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(otherHeard.isEmpty)
    }

    func testAnUnansweredRequestFailsWhenTheConnectionDrops() async throws {
        let host = try await makeHost { _ in
            try await Task.sleep(for: .seconds(30))
            return .null
        }
        let client = makeClient()
        try await connected(to: host, client)
        let pending = Task { try await client.request("hang") }
        try await Task.sleep(for: .milliseconds(200))
        client.disconnect()
        do {
            _ = try await pending.value
            XCTFail("Expected an error")
        } catch {}
    }

    // MARK: Reconnecting

    func testReconnectsAfterTheHostRestarts() async throws {
        let host = try await makeHost()
        let browser = ControlBrowser()
        defer { browser.stop() }
        browser.start()
        try await waitUntil("Bonjour finds the host", seconds: 10) { browser.peer(matching: host.hostName) != nil }
        let peer = try XCTUnwrap(browser.peer(matching: host.hostName))
        let client = makeClient()
        client.connect(to: peer.endpoint, code: host.pairingCode)
        try await client.waitUntilConnected(timeout: .seconds(8))

        // Like the headset app going to the background and back: a new
        // listener (and port), the same code.
        host.suspend()
        try await waitUntil("the client notices") { !client.isConnected }
        XCTAssertEqual(client.phase, .reconnecting)
        host.resume()
        try await waitUntil("the client reconnects", seconds: 20) { client.isConnected }
        try await waitUntil("the host lists it again") { host.clients.count == 1 }
    }
}
