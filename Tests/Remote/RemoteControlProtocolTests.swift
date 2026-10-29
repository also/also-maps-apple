import XCTest

final class RemoteControlProtocolTests: XCTestCase {
    func testSnapshotRoundTrip() throws {
        let state = RemoteControlState(x: -0.8, y: 0.5, turn: 0.2, climb: -1, zoom: 1, fast: true)
        let frame = try RemoteControlMessage(kind: .state, state: state).framed()
        XCTAssertEqual(try RemoteControlMessage.bodySize(Data(frame.prefix(4))), frame.count - 4)
        let decoded = try JSONDecoder().decode(RemoteControlMessage.self, from: frame.dropFirst(4))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.state, state)
        XCTAssertTrue(try XCTUnwrap(decoded.state).isValid)
    }

    func testRejectsMalformedAndOversizedFrames() {
        for bytes: [UInt8] in [[], [0, 1], [0, 0, 0, 0], [0, 0, 16, 1], [255, 255, 255, 255]] {
            XCTAssertThrowsError(try RemoteControlMessage.bodySize(Data(bytes)))
        }
        XCTAssertThrowsError(try RemoteControlMessage(kind: .action, action: String(repeating: "x", count: 5000)).framed())
    }

    func testRejectsNonFiniteAndOutOfRangeControls() {
        XCTAssertTrue(RemoteControlState().isValid)
        XCTAssertFalse(RemoteControlState(x: .nan).isValid)
        XCTAssertFalse(RemoteControlState(turn: .infinity).isValid)
        XCTAssertFalse(RemoteControlState(climb: 1.01).isValid)
        XCTAssertFalse(RemoteControlState(zoom: -1.01).isValid)
    }

    func testDiscreteActionHasSeparateFrame() throws {
        let frame = try RemoteControlMessage(kind: .action, action: "toggleFly").framed()
        let decoded = try JSONDecoder().decode(RemoteControlMessage.self, from: frame.dropFirst(4))
        XCTAssertEqual(decoded.kind, .action)
        XCTAssertEqual(decoded.action, "toggleFly")
        XCTAssertNil(decoded.state)
    }
}
