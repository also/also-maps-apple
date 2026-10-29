import Network
import SwiftUI

/// A controller-only screen: the headset owns the map and its camera.
struct PhoneRemoteControlView: View {
    @State private var remote = RemoteControlSession(role: .controller)
    @State private var selectedPeer: NWBrowser.Result?
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if remote.isConnected {
                    controller
                } else {
                    Form {
                        Section {
                            Text(remote.status)
                            Text("On Vision Pro, open iPhone Controller and enable pairing. Keep both apps active with Wi-Fi enabled.")
                                .foregroundStyle(.secondary)
                        }
                        Section("Nearby headsets") {
                            if remote.peers.isEmpty {
                                Text("Looking for Also Maps…").foregroundStyle(.secondary)
                            }
                            ForEach(remote.peers, id: \.self) { peer in
                                Button {
                                    selectedPeer = peer
                                } label: {
                                    HStack {
                                        Text(RemoteControlSession.name(of: peer))
                                        Spacer()
                                        if selectedPeer == peer { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                        Section("Pairing code from Vision Pro") {
                            TextField("12-digit code", text: $code)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                            Button("Connect") {
                                if let selectedPeer { remote.connect(to: selectedPeer, code: code) }
                            }
                            .disabled(selectedPeer == nil || code.filter { $0.isASCII && $0.isNumber }.count != 12 || remote.isConnecting)
                            Button("Search Again") {
                                selectedPeer = nil
                                remote.browse()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Vision Pro Controller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { remote.stop(); dismiss() }
                }
                if remote.isConnected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Disconnect") { remote.disconnect() }
                    }
                }
            }
        }
        .task { remote.browse() }
        .onDisappear { remote.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                remote.stop()
            } else if !remote.isEnabled {
                selectedPeer = nil
                remote.browse()
            }
        }
    }

    private var controller: some View {
        GeometryReader { geometry in
            let diameter = min(132.0, max(84.0, (geometry.size.width - 120) / 2))
            let compact = geometry.size.height < 350
            VStack(spacing: compact ? 8 : 20) {
                Label("Connected to Vision Pro", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !compact {
                    Text("Left stick moves. Right stick turns and climbs. The centre slider zooms.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    action("Previous", icon: "backward.end", .previousPlace)
                    action("Next", icon: "forward.end", .nextPlace)
                    action("North", icon: "location.north", .faceNorth)
                    action("Fly", icon: "airplane", .toggleFly)
                    if compact {
                        Toggle("Faster", isOn: $remote.controls.fast).toggleStyle(.button)
                    }
                }
                if !compact {
                    Toggle("Faster", isOn: $remote.controls.fast).toggleStyle(.button)
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    Joystick(label: "move", onChange: { value in
                        remote.controls.x = value.x
                        remote.controls.y = value.y
                    }, diameter: diameter)
                    Spacer(minLength: 8)
                    TiltControl(onChange: { remote.controls.zoom = $0 }, height: diameter, label: "Zoom in or out")
                    Spacer(minLength: 8)
                    Joystick(label: "turn · climb", onChange: { value in
                        remote.controls.turn = value.x
                        remote.controls.climb = value.y
                    }, diameter: diameter)
                }
            }
            .padding(compact ? 8 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(white: 0.12))
        .preferredColorScheme(.dark)
    }

    private func action(_ title: String, icon: String, _ action: MapInput.Action) -> some View {
        Button { remote.sendAction(action) } label: {
            VStack {
                Image(systemName: icon)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
