import Foundation

/// The remote-control wire format, version 2: one length-prefixed JSON
/// message per frame on a TLS stream (see docs/remote-control.md). One
/// envelope type carries every kind of message, with the fields its kind
/// uses; the rest are left out of the JSON.
struct ControlMessage: Codable, Equatable {
    static let version = 2

    enum Kind: String, Codable {
        /// First message each way: who's there and what they want or offer.
        case hello
        /// Liveness only; any frame counts, this is sent when nothing else is.
        case ping
        /// A joystick snapshot from a controller, acknowledged by `inputAck`.
        case input, inputAck
        /// A button press (a `MapInput.Action` raw value).
        case action
        /// A call (`id`, `method`, `params`) and its answer (`id`, `ok`,
        /// `result` or `error`).
        case request, response
        /// Something that happened on the host (`event`, `data`).
        case event
    }

    var type: Kind
    var v: Int = Self.version
    var hello: ControlHello?
    var input: RemoteControlState?
    var action: String?
    var id: Int?
    var method: String?
    var params: JSONValue?
    var ok: Bool?
    var result: JSONValue?
    var error: String?
    var event: String?
    var data: JSONValue?

    static func request(id: Int, method: String, params: JSONValue?) -> ControlMessage {
        ControlMessage(type: .request, id: id, method: method, params: params)
    }

    static func response(id: Int, result: JSONValue) -> ControlMessage {
        ControlMessage(type: .response, id: id, ok: true, result: result)
    }

    static func failure(id: Int, error: String) -> ControlMessage {
        ControlMessage(type: .response, id: id, ok: false, error: error)
    }

    static func event(_ name: String, data: JSONValue?) -> ControlMessage {
        ControlMessage(type: .event, event: name, data: data)
    }

    // MARK: Framing

    /// Frames from a client: input, actions, requests. Small, so a bad peer
    /// can't make the host allocate much.
    static let clientFrameLimit = 64 * 1024
    /// Frames from a host: responses can carry a screenshot.
    static let hostFrameLimit = 16 * 1024 * 1024

    /// A 4-byte big-endian length, then the JSON body.
    func framed(limit: Int = Self.hostFrameLimit) throws -> Data {
        let body = try JSONEncoder().encode(self)
        guard body.count <= limit else { throw ProtocolError.invalidSize }
        var size = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(body)
        return frame
    }

    static func bodySize(_ header: Data, limit: Int) throws -> Int {
        guard header.count == 4 else { throw ProtocolError.invalidSize }
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...limit).contains(size) else { throw ProtocolError.invalidSize }
        return size
    }

    static func decode(_ body: Data) throws -> ControlMessage {
        let message = try JSONDecoder().decode(ControlMessage.self, from: body)
        guard message.v == version else { throw ProtocolError.unsupportedVersion(message.v) }
        return message
    }

    enum ProtocolError: Error, Equatable {
        case invalidSize
        case unsupportedVersion(Int)
    }
}

/// Who's on each end. A client says what it is and what it wants; a host
/// says what it is and which methods it has.
struct ControlHello: Codable, Equatable {
    /// "Ryan's iPhone", "alsomaps-control mcp", "Also Maps on Ryan's Mac".
    var name: String
    /// A client's: "phone", "cli", "mcp". A host's: "host".
    var kind: String
    /// A host's platform: "macOS", "visionOS", "iOS".
    var platform: String?
    /// A client asks for `events` to be sent events.
    var wants: [String]?
    /// A host lists the request methods it answers.
    var methods: [String]?
    /// A host lists the event names it sends.
    var events: [String]?
}

/// One joystick snapshot: every axis −1…1.
struct RemoteControlState: Codable, Equatable {
    var x = 0.0
    var y = 0.0
    var turn = 0.0
    var climb = 0.0
    var zoom = 0.0
    var fast = false

    var isZero: Bool { self == RemoteControlState() }

    /// Reject malformed input instead of propagating NaN or unbounded rates.
    var isValid: Bool {
        [x, y, turn, climb, zoom].allSatisfy { $0.isFinite && (-1...1).contains($0) }
    }
}

/// What a Debug Mac app writes so `alsomaps-control` on the same Mac can
/// connect without anyone typing the code: its name, port and code.
struct ControlLocalInfo: Codable, Equatable {
    var name: String
    var port: UInt16
    var code: String
    var platform: String
    var pid: Int32

    /// ~/Library/Application Support/AlsoMaps/control.json. Debug Mac
    /// builds run unsandboxed, so the app and the CLI agree on this.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AlsoMaps/control.json")
    }
}
