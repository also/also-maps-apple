import Darwin
import Foundation
import Network

/// Finds an Also Maps app and connects to it: "local" is the Debug Mac app
/// on this Mac (its control.json gives the port and code), anything else a
/// Bonjour name on the network, with a code from the caller, the code book
/// or ALSOMAPS_CONTROL_CODE.
@MainActor
final class Connector {
    struct Device {
        var name: String
        var platform: String?
        var isLocal: Bool
    }

    let client: ControlClient
    private(set) var deviceName: String?
    private let browser = ControlBrowser()

    init(kind: String, wantsEvents: Bool) {
        client = ControlClient(name: "alsomaps-control \(kind) (\(NSUserName()))", kind: kind, wantsEvents: wantsEvents)
    }

    /// The Debug Mac app's details, if it's running.
    static func localInfo() -> ControlLocalInfo? {
        guard let data = try? Data(contentsOf: ControlLocalInfo.defaultURL),
              let info = try? JSONDecoder().decode(ControlLocalInfo.self, from: data),
              kill(info.pid, 0) == 0 || errno == EPERM
        else { return nil }
        return info
    }

    /// The local app (if running) and what Bonjour finds in `seconds`.
    func devices(seconds: Double = 2) async -> [Device] {
        var devices: [Device] = []
        let local = Self.localInfo()
        if let local { devices.append(Device(name: local.name, platform: local.platform, isLocal: true)) }
        browser.start()
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        for peer in browser.peers where peer.name != local?.name {
            devices.append(Device(name: peer.name, platform: peer.platform, isLocal: false))
        }
        browser.stop()
        return devices
    }

    /// Connects, replacing any connection. `device` nil means the local
    /// app if it's running, else the only app on the network.
    @discardableResult
    func connect(to device: String?, code: String?) async throws -> String {
        let (endpoint, name, resolvedCode, isLocal) = try await resolve(device, code: code)
        client.connect(to: endpoint, code: resolvedCode)
        try await client.waitUntilConnected(timeout: .seconds(15))
        deviceName = client.host?.name ?? name
        if !isLocal { ControlCodeBook.remember(resolvedCode, for: name) }
        return deviceName ?? name
    }

    /// Connects the first time a map tool or command needs it.
    func ensureConnected(default device: String?, code: String?) async throws {
        switch client.phase {
        case .connected: return
        case .connecting, .reconnecting: try await client.waitUntilConnected(timeout: .seconds(15))
        case .idle: try await connect(to: device, code: code)
        }
    }

    private func resolve(_ device: String?, code: String?) async throws
        -> (endpoint: NWEndpoint, name: String, code: String, isLocal: Bool) {
        if device == nil || device == "local" {
            if let local = Self.localInfo(), let port = NWEndpoint.Port(rawValue: local.port) {
                return (.hostPort(host: "127.0.0.1", port: port), local.name, code ?? local.code, true)
            }
            if device == "local" {
                throw ControlClient.Failure("No Debug Also Maps app with remote control on is running on this Mac. Launch it with ALSOMAPS_CONTROL=1, or turn on Remote Control in the app. (Looked for \(ControlLocalInfo.defaultURL.path).)")
            }
        }
        browser.start()
        defer { browser.stop() }
        let deadline = ContinuousClock.now + .seconds(5)
        var peer: ControlBrowser.Peer?
        while ContinuousClock.now < deadline {
            if let device {
                peer = browser.peer(matching: device)
            } else if browser.peers.count == 1 {
                peer = browser.peers.first
            }
            if peer != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let peer else {
            let names = browser.peers.map(\.name)
            if let device {
                throw ControlClient.Failure("Found no Also Maps named “\(device)”. On the network: \(names.isEmpty ? "none" : names.joined(separator: ", ")).")
            }
            throw ControlClient.Failure(names.isEmpty
                ? "Found no Also Maps with remote control on, on this Mac or the network."
                : "Several Also Maps on the network; say which: \(names.joined(separator: ", ")).")
        }
        let environmentCode = ProcessInfo.processInfo.environment["ALSOMAPS_CONTROL_CODE"]
        guard let resolvedCode = code ?? ControlCodeBook.code(for: peer.name) ?? environmentCode else {
            throw ControlClient.Failure("“\(peer.name)” needs its 6-digit pairing code (shown in its Remote Control panel). Pass it with --code, or as code to connect.")
        }
        return (peer.endpoint, peer.name, resolvedCode, false)
    }
}
