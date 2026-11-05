import XCTest

final class ControlProtocolTests: XCTestCase {
    func testInputRoundTrip() throws {
        let state = RemoteControlState(x: -0.8, y: 0.5, turn: 0.2, climb: -1, zoom: 1, fast: true)
        let frame = try ControlMessage(type: .input, input: state).framed()
        XCTAssertEqual(try ControlMessage.bodySize(Data(frame.prefix(4)), limit: ControlMessage.clientFrameLimit),
                       frame.count - 4)
        let decoded = try ControlMessage.decode(frame.dropFirst(4))
        XCTAssertEqual(decoded.type, .input)
        XCTAssertEqual(decoded.v, ControlMessage.version)
        XCTAssertEqual(decoded.input, state)
        XCTAssertNil(decoded.action)
    }

    func testRequestResponseAndEventRoundTrip() throws {
        for message in [
            ControlMessage.request(id: 7, method: "command.run", params: ["command": ["climb": ["meters": 100]]]),
            .response(id: 7, result: ["ok": true]),
            .failure(id: 8, error: "Nope"),
            .event("camera", data: ["latitude": 1.5]),
            ControlMessage(type: .hello, hello: ControlHello(name: "Mac", kind: "host", platform: "macOS",
                                                              methods: ["state.get"], events: ["camera"])),
        ] {
            XCTAssertEqual(try ControlMessage.decode(message.framed().dropFirst(4)), message)
        }
    }

    func testOnlyTheFieldsInUseAreSent() throws {
        let json = String(decoding: try JSONEncoder().encode(ControlMessage(type: .ping)), as: UTF8.self)
        XCTAssertEqual(json.filter { $0 == ":" }.count, 2, json) // type and v
    }

    func testRejectsMalformedAndOversizedFrames() {
        for bytes: [UInt8] in [[], [0, 1], [0, 0, 0, 0], [0, 1, 0, 1], [255, 255, 255, 255]] {
            XCTAssertThrowsError(try ControlMessage.bodySize(Data(bytes), limit: ControlMessage.clientFrameLimit))
        }
        let big = ControlMessage(type: .action, action: String(repeating: "x", count: ControlMessage.clientFrameLimit))
        XCTAssertThrowsError(try big.framed(limit: ControlMessage.clientFrameLimit))
        XCTAssertNoThrow(try big.framed(limit: ControlMessage.hostFrameLimit))
    }

    func testRejectsOtherVersions() throws {
        var message = ControlMessage(type: .ping)
        message.v = 1
        let body = try JSONEncoder().encode(message)
        XCTAssertThrowsError(try ControlMessage.decode(body)) { error in
            XCTAssertEqual(error as? ControlMessage.ProtocolError, .unsupportedVersion(1))
        }
        // Version 1's messages had no type field.
        XCTAssertThrowsError(try ControlMessage.decode(Data(#"{"kind":"hello","version":1}"#.utf8)))
    }

    func testRejectsNonFiniteAndOutOfRangeControls() {
        XCTAssertTrue(RemoteControlState().isValid)
        XCTAssertTrue(RemoteControlState().isZero)
        XCTAssertFalse(RemoteControlState(x: .nan).isValid)
        XCTAssertFalse(RemoteControlState(turn: .infinity).isValid)
        XCTAssertFalse(RemoteControlState(climb: 1.01).isValid)
        XCTAssertFalse(RemoteControlState(zoom: -1.01).isValid)
    }

    func testCodes() {
        XCTAssertTrue(ControlTransport.isValidCode("012345"))
        XCTAssertFalse(ControlTransport.isValidCode("12345"))
        XCTAssertFalse(ControlTransport.isValidCode("12345a"))
        XCTAssertFalse(ControlTransport.isValidCode("１２３４５６"))
        for _ in 0..<20 { XCTAssertTrue(ControlTransport.isValidCode(ControlTransport.newCode())) }
    }
}
