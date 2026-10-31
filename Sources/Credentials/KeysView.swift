import SwiftUI

extension View {
    /// Asks how to load the map the first time there's no key, in place of
    /// this view, and keeps the app's key fresh while this scene is active.
    func credentialGate() -> some View {
        modifier(CredentialGate())
    }
}

private struct CredentialGate: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    private var store: CredentialStore { .shared }

    func body(content: Content) -> some View {
        Group {
            if store.needsChoice {
                KeyChoiceView()
            } else {
                content
            }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refreshAppKeys()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }
}

/// The first launch's choice. Without App Attest, only one option is left.
private struct KeyChoiceView: View {
    private var store: CredentialStore { .shared }

    var body: some View {
        NavigationStack {
            if store.canUseAppKeys {
                VStack(spacing: 24) {
                    Text("How should Also Maps load the map?")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    VStack(spacing: 8) {
                        Button("Use the App's Key") { store.choose(.app) }
                            .buttonStyle(.borderedProminent)
                        Text("Free and ready to go. Everyone shares it, so the map may be throttled.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 8) {
                        NavigationLink("Use Your Own Key") { KeysView() }
                        Text("Sign up with Google or Cesium, experiment, and use your own limits.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(32)
                .frame(maxWidth: 480)
            } else {
                KeysView()
            }
        }
    }
}

/// Where the user adds their own keys, or chooses the app's.
struct KeysView: View {
    private var store: CredentialStore { .shared }

    var body: some View {
        Form {
            if store.canUseAppKeys {
                Section {
                    Toggle("Use the app's key", isOn: Binding(get: { store.choice == .app },
                                                              set: { store.choose($0 ? .app : .own) }))
                    if let problem = store.appKeyProblem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Shared by everyone, so it may be throttled. A key of your own below always takes priority.")
                }
            }
            ForEach(CredentialService.allCases) { service in
                OwnKeySection(service: service)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keys")
    }
}

private struct OwnKeySection: View {
    let service: CredentialService

    @State private var text = ""
    @State private var isChecking = false
    @State private var message: String?

    private var store: CredentialStore { .shared }

    var body: some View {
        Section {
            if store.ownKeys[service] != nil {
                LabeledContent("Your key", value: "Saved")
                Button("Remove Key", role: .destructive) {
                    try? store.setOwnKey(nil, for: service)
                    message = nil
                }
            } else {
                SecureField("Paste your key", text: $text)
                    .autocorrectionDisabled()
                    .onChange(of: text) { message = nil }
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button(isChecking ? "Checking…" : "Save") {
                    Task { await save() }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(service.name)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(service.help)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Get a \(service.name) key", destination: service.signupURL)
            }
        }
    }

    private func save() async {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isChecking = true
        defer { isChecking = false }
        // Saved unless the service says it's bad: being offline, or out of
        // quota, doesn't make a key wrong.
        if case let .rejected(reason) = await service.check(key) {
            message = reason
            return
        }
        do {
            try store.setOwnKey(key, for: service)
            text = ""
            message = nil
        } catch {
            message = "The key couldn't be saved: \(error.localizedDescription)"
        }
    }
}

extension CredentialService {
    fileprivate var help: String {
        switch self {
        case .googleMaps:
            """
            Create a Google Cloud project with billing turned on, enable the Map Tiles API, and create a key. \
            Google bills each map session, when the app starts or about every three hours, not each tile. \
            The free tier currently covers 1,000 sessions a month. \
            If you restrict the key, allow the iOS app dev.also.maps.
            """
        case .cesiumIon:
            "A free Cesium ion account includes the terrain and buildings. Create a token with the assets:read scope."
        }
    }

    enum KeyCheck: Equatable {
        case usable
        case rejected(String)
    }

    /// Tries the key with one request; for Google, that's one map session.
    fileprivate func check(_ key: String) async -> KeyCheck {
        var components: URLComponents
        switch self {
        case .googleMaps:
            components = URLComponents(string: "https://tile.googleapis.com/v1/3dtiles/root.json")!
            components.queryItems = [URLQueryItem(name: "key", value: key)]
        case .cesiumIon:
            components = URLComponents(string: "https://api.cesium.com/v1/assets/1/endpoint")!
            components.queryItems = [URLQueryItem(name: "access_token", value: key)]
        }
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        // Keys restricted to this app need this, as tile requests send it.
        request.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        let session = URLSession(configuration: .ephemeral)
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              [400, 401, 403].contains(status) else { return .usable }
        return .rejected("\(name) rejected this key (HTTP \(status)). Check the key and that the API is enabled.")
    }
}
