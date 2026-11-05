import Foundation

/// Versioned, bounded messages on a length-prefixed TLS stream. Continuous
/// input is a full snapshot; actions travel separately so short taps survive.
struct RemoteControlMessage: Codable {
    static let version = 1
    static let maximumSize = 4096
    enum Kind: String, Codable { case hello, state, action, acknowledgement }
    var kind: Kind
    var version: Int = Self.version
    var state: RemoteControlState?
    var action: String?

    func framed() throws -> Data {
        let body = try JSONEncoder().encode(self)
        guard body.count <= Self.maximumSize else { throw ProtocolError.invalidSize }
        var size = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(body)
        return frame
    }

    static func bodySize(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw ProtocolError.invalidSize }
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...maximumSize).contains(size) else { throw ProtocolError.invalidSize }
        return size
    }

    enum ProtocolError: Error { case invalidSize }
}

struct RemoteControlState: Codable, Equatable {
    var x = 0.0
    var y = 0.0
    var turn = 0.0
    var climb = 0.0
    var zoom = 0.0
    var fast = false

    /// Reject malformed input instead of propagating NaN or unbounded rates.
    var isValid: Bool {
        [x, y, turn, climb, zoom].allSatisfy { $0.isFinite && (-1...1).contains($0) }
    }
}
