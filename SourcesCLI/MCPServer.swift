import Foundation

/// A Model Context Protocol server on stdin and stdout (newline-delimited
/// JSON-RPC 2.0), whose tools fly a connected Also Maps app. One persistent
/// connection: it reconnects by itself, and keeps the app's events for
/// `recent_events`. Logs go to stderr; stdout is only protocol.
@MainActor
final class MCPServer {
    private let connector = Connector(kind: "mcp", wantsEvents: true)
    private let defaultDevice: String?
    private let defaultCode: String?
    private var events: [(sequence: Int, name: String, data: JSONValue?, time: Date)] = []
    private var sequence = 0
    private static let keptEvents = 500
    private static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    init(device: String?, code: String?) {
        defaultDevice = device
        defaultCode = code
        connector.client.onEvent = { [weak self] name, data in self?.record(name, data) }
        connector.client.onConnect = { hello in stderrLog("connected to \(hello.name) (\(hello.platform ?? "?"))") }
    }

    func run() async {
        stderrLog("MCP server ready on stdin/stdout")
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { handle(trimmed) }
            }
        } catch {
            stderrLog("stdin failed: \(error)")
        }
        stderrLog("stdin closed; exiting")
    }

    // MARK: JSON-RPC

    private func handle(_ line: String) {
        guard let message = try? JSONValue.parse(line), case .object = message else {
            reply(id: .null, error: (-32700, "Parse error"))
            return
        }
        let method = message["method"]?.string
        // Notifications (initialized, cancelled) have no id and get no reply.
        guard let id = message["id"], id != .null else { return }
        guard let method else {
            reply(id: id, error: (-32600, "Invalid request"))
            return
        }
        let params = message["params"]
        switch method {
        case "initialize":
            let requested = params?["protocolVersion"]?.string ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            reply(id: id, result: [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "alsomaps-control", "version": "0.1"],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            reply(id: id, result: [:])
        case "tools/list":
            reply(id: id, result: ["tools": .array(ControlTools.all.map { tool -> JSONValue in
                ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
            })])
        case "tools/call":
            guard let name = params?["name"]?.string else {
                reply(id: id, error: (-32602, "tools/call needs a name"))
                return
            }
            let arguments = params?["arguments"] ?? [:]
            Task {
                let result = await callTool(name, arguments: arguments)
                reply(id: id, result: result)
            }
        default:
            reply(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    private func reply(id: JSONValue, result: JSONValue) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func reply(id: JSONValue, error: (code: Int, message: String)) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]])
    }

    private func write(_ message: JSONValue) {
        FileHandle.standardOutput.write(Data((message.jsonString + "\n").utf8))
    }

    // MARK: Tools

    private func callTool(_ name: String, arguments: JSONValue) async -> JSONValue {
        do {
            let text: String
            switch name {
            case "list_devices":
                text = try await listDevices()
            case "connect":
                guard let device = arguments["device"]?.string else {
                    throw ControlTools.ArgumentError("connect needs a device")
                }
                let connected = try await connector.connect(to: device, code: arguments["code"]?.string)
                text = "Connected to \(connected)."
            case "recent_events":
                text = recentEvents(after: arguments["after"]?.number.map { Int($0) })
            default:
                let (method, params) = try ControlTools.request(for: name, arguments: arguments)
                try await connector.ensureConnected(default: defaultDevice, code: defaultCode)
                let result = try await connector.client.request(method, params, timeout: .seconds(180))
                text = result.prettyString
            }
            return ["content": [["type": "text", "text": .string(text)]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": .string(error.localizedDescription)]], "isError": true]
        }
    }

    private func listDevices() async throws -> String {
        let devices = await connector.devices(seconds: 2)
        let connected = connector.client.isConnected ? connector.client.host?.name : nil
        var lines = devices.map { device in
            var line = device.isLocal ? "local: \(device.name)" : device.name
            if let platform = device.platform { line += " (\(platform))" }
            if device.name == connected { line += " — connected" }
            return line
        }
        if lines.isEmpty { lines = ["No Also Maps with remote control on, on this Mac or the network."] }
        if let host = connector.client.host {
            lines.append("Connected host methods: \((host.methods ?? []).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func record(_ name: String, _ data: JSONValue?) {
        sequence += 1
        events.append((sequence, name, data, Date()))
        if events.count > Self.keptEvents { events.removeFirst(events.count - Self.keptEvents) }
    }

    private func recentEvents(after: Int?) -> String {
        let chosen = after.map { after in events.filter { $0.sequence > after } } ?? Array(events.suffix(20))
        guard !chosen.isEmpty else {
            return "No events\(after.map { " after \($0)" } ?? ""). Latest sequence number: \(sequence)."
        }
        let formatter = ISO8601DateFormatter()
        return chosen.map { event in
            JSONValue.object(["sequence": .number(Double(event.sequence)), "event": .string(event.name),
                              "time": .string(formatter.string(from: event.time)), "data": event.data ?? .null]).jsonString
        }.joined(separator: "\n")
    }

    private static let instructions = """
        Flies a running Also Maps app: a 3D map of Google's photorealistic tiles on a Mac, Vision Pro or iPhone. \
        Map tools connect to the Debug Mac app on this Mac by themselves; use list_devices and connect for another device. \
        Amounts are metres and degrees. Motions ease over about a second and, by default, answer when finished. \
        Call get_state to see where the camera is, and wait_until_settled before judging what's on screen.
        """
}

/// Everything but protocol goes to stderr.
func stderrLog(_ message: String) {
    FileHandle.standardError.write(Data("[alsomaps-control] \(message)\n".utf8))
}
