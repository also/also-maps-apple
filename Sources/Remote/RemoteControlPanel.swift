import SwiftUI

/// Turning remote control on, the code to pair with, and who's connected.
/// In a window on visionOS, a popover on the Mac.
struct RemoteControlPanel: View {
    let host: ControlHost

    var body: some View {
        Form {
            Section {
                Toggle("Allow Remote Control", isOn: Binding(
                    get: { host.isEnabled },
                    set: { $0 ? host.start() : host.stop() }))
                LabeledContent("Status", value: host.status)
            } footer: {
                Text("Lets an iPhone, the alsomaps-control CLI or an agent (over MCP) on this network fly the map.")
            }
            if host.isEnabled {
                Section("Pairing") {
                    LabeledContent("Name", value: host.hostName)
                    LabeledContent("Code") {
                        Text(host.pairingCode)
                            .font(.title.monospacedDigit())
                            .textSelection(.enabled)
                            .accessibilityLabel("Pairing code \(host.pairingCode)")
                    }
                    Button("New Code") { host.newCode() }
                    Text("Enter the code on the iPhone, or pass it to alsomaps-control with --code. The code stays the same until you make a new one; a new one disconnects everyone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Connected") {
                    if host.clients.isEmpty {
                        Text("No one").foregroundStyle(.secondary)
                    }
                    ForEach(host.clients) { client in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(client.name)
                                Text(client.kind).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Disconnect") { host.disconnect(client) }
                        }
                    }
                }
                if !host.log.isEmpty {
                    Section("Recent Requests") {
                        ForEach(Array(host.log.prefix(12).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

#if os(visionOS)
struct RemoteControlHostView: View {
    static let windowID = "remote-control"
    @Environment(MapModel.self) private var model

    var body: some View {
        NavigationStack {
            RemoteControlPanel(host: model.control.host)
                .navigationTitle("Remote Control")
        }
    }
}
#endif
