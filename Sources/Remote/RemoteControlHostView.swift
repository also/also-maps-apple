#if os(visionOS)
import SwiftUI

struct RemoteControlHostView: View {
    static let windowID = "remote-control"
    @Environment(MapModel.self) private var model

    var body: some View {
        let remote = model.remoteControl
        NavigationStack {
            Form {
                Section {
                    Toggle("Allow iPhone Controller", isOn: Binding(
                        get: { remote.isEnabled },
                        set: { $0 ? remote.startHosting() : remote.stop() }))
                    LabeledContent("Status", value: remote.status)
                }
                if remote.isEnabled {
                    Section("Pair your iPhone") {
                        Text("Open Also Maps on iPhone, tap the controller button, and select this headset.")
                        LabeledContent("Headset", value: remote.hostName)
                        Text(remote.pairingCode)
                            .font(.largeTitle.monospacedDigit())
                            .textSelection(.enabled)
                            .accessibilityLabel("Pairing code \(remote.pairingCode)")
                        Text("Enter this code on iPhone. Keep both apps active and Wi-Fi enabled. A shared Wi-Fi network is optional.")
                            .foregroundStyle(.secondary)
                    }
                    if remote.isConnected {
                        Button("Disconnect Controller") { remote.disconnect() }
                    }
                }
            }
            .navigationTitle("iPhone Controller")
        }
    }
}

#endif
