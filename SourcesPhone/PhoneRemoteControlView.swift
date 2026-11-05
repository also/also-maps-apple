import Network
import SwiftUI

/// A controller-only screen: the other device (Vision Pro or a Mac) owns
/// the map and its camera.
struct PhoneRemoteControlView: View {
    @State private var browser = ControlBrowser()
    @State private var remote = ControlClient(name: UIDevice.current.name, kind: "phone", wantsEvents: false,
                                              sendsInput: true)
    @State private var selectedPeer: ControlBrowser.Peer?
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
                            Text(remote.isConnecting ? remote.status : browser.status)
                            if !remote.isConnecting, remote.status != "Not connected" {
                                Text(remote.status).foregroundStyle(.secondary)
                            }
                            Text("On Vision Pro or the Mac, open Remote Control and turn on Allow Remote Control. Keep both apps active with Wi-Fi on.")
                                .foregroundStyle(.secondary)
                        }
                        Section("Nearby") {
                            if browser.peers.isEmpty {
                                Text("Looking for Also Maps…").foregroundStyle(.secondary)
                            }
                            ForEach(browser.peers) { peer in
                                Button {
                                    selectedPeer = peer
                                    if let saved = ControlCodeBook.code(for: peer.name) { code = saved }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(peer.name)
                                            if let platform = peer.platform {
                                                Text(platform).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if selectedPeer == peer { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                        Section("Pairing code") {
                            TextField("6-digit code", text: $code)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                            Button("Connect") {
                                if let selectedPeer { remote.connect(to: selectedPeer.endpoint, code: code) }
                            }
                            .disabled(selectedPeer == nil || !ControlTransport.isValidCode(code.filter { $0.isASCII && $0.isNumber })
                                      || remote.isConnecting)
                            Button("Search Again") {
                                selectedPeer = nil
                                browser.start()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Remote Controller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { stop(); dismiss() }
                }
                if remote.isConnected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Disconnect") { remote.disconnect() }
                    }
                }
            }
        }
        .task { browser.start() }
        .onDisappear { stop() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Connections don't survive the background.
                stop()
            case .active:
                if !browser.isBrowsing { browser.start() }
            default:
                // Inactive (Control Center, a notification) keeps the
                // connection; only the sticks are let go.
                remote.controls = RemoteControlState()
            }
        }
        .onChange(of: remote.host) { _, host in
            // Remember a code that worked, for next time.
            if let host, let selectedPeer, host.name == selectedPeer.name {
                ControlCodeBook.remember(code.filter { $0.isASCII && $0.isNumber }, for: selectedPeer.name)
            }
        }
    }

    private func stop() {
        remote.disconnect()
        browser.stop()
    }

    private var controller: some View {
        GeometryReader { geometry in
            let diameter = min(132.0, max(84.0, (geometry.size.width - 120) / 2))
            let compact = geometry.size.height < 350
            VStack(spacing: compact ? 8 : 20) {
                Label("Connected to \(remote.host?.name ?? "the map")", systemImage: "checkmark.circle.fill")
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
        Button { remote.sendAction(action.rawValue) } label: {
            VStack {
                Image(systemName: icon)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
