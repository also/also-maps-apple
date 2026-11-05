import Foundation

/// alsomaps-control: fly a running Also Maps app from the command line, or
/// serve MCP so an agent can. See docs/remote-control.md.
@main
struct AlsoMapsControl {
    static let usage = """
        Usage: alsomaps-control <command> [options]

        Commands:
          list                     Also Maps apps with remote control on: this Mac's, and the network's
          state                    Print the camera, altitude and tile loading
          send '<MapCommand JSON>' Run one command, e.g. '{"climb":{"meters":300}}' (see docs/commands.md)
          call <method> ['<JSON>'] Call any host method, e.g. tiles.waitSettled '{"timeoutSeconds":10}'
          watch                    Print the host's events as JSON lines until interrupted
          mcp                      Serve MCP on stdin/stdout

        Options:
          --to <device>   "local" (the Debug Mac app on this Mac) or a name from list. Default: local if
                          it's running, else the only app on the network
          --code <code>   The device's 6-digit pairing code. Remembered once it works; also read from
                          ALSOMAPS_CONTROL_CODE
          --wait          send: answer when the motion has finished
          --seconds <n>   list: how long to look (default 2)
        """

    @MainActor
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty, !["-h", "--help", "help"].contains(arguments[0]) else {
            print(usage)
            exit(arguments.isEmpty ? 1 : 0)
        }
        let command = arguments.removeFirst()
        do {
            let options = try Options(&arguments)
            try await run(command, arguments, options)
            exit(0)
        } catch {
            stderrLog(error.localizedDescription)
            exit(1)
        }
    }

    struct Options {
        var device: String?
        var code: String?
        var wait = false
        var seconds = 2.0

        /// Takes the options out of `arguments`, leaving the positional ones.
        init(_ arguments: inout [String]) throws {
            var rest: [String] = []
            var index = 0
            func value(_ flag: String) throws -> String {
                index += 1
                guard index < arguments.count else { throw ControlTools.ArgumentError("\(flag) needs a value") }
                return arguments[index]
            }
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--to": device = try value(argument)
                case "--code": code = try value(argument)
                case "--wait": wait = true
                case "--seconds":
                    guard let seconds = try Double(value(argument)) else {
                        throw ControlTools.ArgumentError("--seconds needs a number")
                    }
                    self.seconds = seconds
                default: rest.append(argument)
                }
                index += 1
            }
            arguments = rest
        }
    }

    @MainActor
    static func run(_ command: String, _ arguments: [String], _ options: Options) async throws {
        switch command {
        case "list":
            let devices = await Connector(kind: "cli", wantsEvents: false).devices(seconds: options.seconds)
            if devices.isEmpty { stderrLog("No Also Maps with remote control on, on this Mac or the network.") }
            for device in devices {
                print([device.isLocal ? "local" : "network", device.name, device.platform ?? "?"].joined(separator: "\t"))
            }
        case "state":
            let connector = try await connected(options, wantsEvents: false)
            print(try await connector.client.request("state.get").prettyString)
        case "send":
            guard let text = arguments.first else { throw ControlTools.ArgumentError("send needs a command's JSON") }
            let command = try parse(text)
            let connector = try await connected(options, wantsEvents: false)
            let result = try await connector.client.request(
                "command.run", ["command": command, "wait": .string(options.wait ? "finished" : "started")])
            print(result.prettyString)
            if result["ok"]?.bool == false { exit(2) }
        case "call":
            guard let method = arguments.first else { throw ControlTools.ArgumentError("call needs a method") }
            let params = try arguments.dropFirst().first.map(parse)
            let connector = try await connected(options, wantsEvents: false)
            print(try await connector.client.request(method, params, timeout: .seconds(600)).prettyString)
        case "watch":
            let connector = try await connected(options, wantsEvents: true)
            connector.client.onEvent = { name, data in
                print(JSONValue.object(["event": .string(name), "data": data ?? .null]).jsonString)
            }
            stderrLog("watching \(connector.deviceName ?? "the map"); Ctrl-C to stop")
            var lastStatus = ""
            while true {
                try await Task.sleep(for: .seconds(1))
                // Reconnects are automatic; say when they happen.
                if connector.client.status != lastStatus {
                    lastStatus = connector.client.status
                    stderrLog(lastStatus)
                }
            }
        case "mcp":
            await MCPServer(device: options.device, code: options.code).run()
        default:
            throw ControlTools.ArgumentError("Unknown command \(command).\n\n\(usage)")
        }
    }

    @MainActor
    private static func connected(_ options: Options, wantsEvents: Bool) async throws -> Connector {
        let connector = Connector(kind: "cli", wantsEvents: wantsEvents)
        let name = try await connector.connect(to: options.device, code: options.code)
        stderrLog("connected to \(name)")
        return connector
    }

    private static func parse(_ text: String) throws -> JSONValue {
        do {
            return try JSONValue.parse(text)
        } catch {
            throw ControlTools.ArgumentError("Not JSON: \(text)")
        }
    }
}
