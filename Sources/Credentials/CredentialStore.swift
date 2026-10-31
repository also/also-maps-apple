import Foundation
import Observation
import Security

/// A service the app needs a key for.
enum CredentialService: String, CaseIterable, Identifiable {
    case googleMaps
    case cesiumIon

    var id: String { rawValue }

    var name: String {
        switch self {
        case .googleMaps: "Google Maps"
        case .cesiumIon: "Cesium ion"
        }
    }

    var environmentVariable: String {
        switch self {
        case .googleMaps: "GOOGLE_MAPS_API_KEY"
        case .cesiumIon: "CESIUM_ION_TOKEN"
        }
    }

    var infoKey: String {
        switch self {
        case .googleMaps: "GoogleMapsAPIKey"
        case .cesiumIon: "CesiumIonToken"
        }
    }

    var signupURL: URL {
        switch self {
        case .googleMaps: URL(string: "https://developers.google.com/maps/documentation/tile/get-api-key")!
        case .cesiumIon: URL(string: "https://ion.cesium.com/tokens")!
        }
    }
}

/// Stored strings, one per account. Kept behind this so tests don't touch the
/// Keychain. `synchronizable` items follow the user between their devices.
protocol CredentialStorage {
    func read(account: String) -> Data?
    func write(_ data: Data, account: String, synchronizable: Bool) throws
    func delete(account: String)
}

struct KeychainStorage: CredentialStorage {
    private let service = "dev.also.maps.credentials"

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
         kSecUseDataProtectionKeychain as String: true]
    }

    #if os(macOS)
    /// Debug Mac builds aren't provisioned for the data protection keychain,
    /// so they use the login keychain, which doesn't sync.
    private func loginQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    #endif

    func read(account: String) -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(request as CFDictionary, &result)
        #if os(macOS)
        if status != errSecSuccess {
            var login = loginQuery(account: account)
            login[kSecReturnData as String] = true
            login[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(login as CFDictionary, &result)
        }
        #endif
        return status == errSecSuccess ? result as? Data : nil
    }

    func write(_ data: Data, account: String, synchronizable: Bool) throws {
        delete(account: account)
        var attributes = query(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrSynchronizable as String] = synchronizable
        attributes[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(attributes as CFDictionary, nil)
        #if os(macOS)
        if status == errSecMissingEntitlement {
            var login = loginQuery(account: account)
            login[kSecValueData as String] = data
            status = SecItemAdd(login as CFDictionary, nil)
        }
        #endif
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
        #if os(macOS)
        SecItemDelete(loginQuery(account: account) as CFDictionary)
        #endif
    }
}

/// Which key the app uses for each service. In order: a scheme's environment
/// variable, the user's own key, the app's shared key (fetched by
/// `AppKeyClient`, if they chose it), then a key built into a development or
/// tvOS build. Release builds on other platforms have none built in.
@MainActor
@Observable
final class CredentialStore {
    enum Choice: String {
        /// The app's shared key, for any service without the user's own.
        case app
        /// Only the user's own keys.
        case own
    }

    private static let choiceKey = "KeyChoice"
    /// Windows each refresh, and a rejected key can be reported every frame.
    private static let minimumRefreshInterval: TimeInterval = 60

    static let shared: CredentialStore = {
        #if os(tvOS)
        CredentialStore(storage: KeychainStorage(), client: nil, supportsOwnKeys: false)
        #else
        CredentialStore(storage: KeychainStorage(), client: AppKeyClient.live(storage: KeychainStorage()))
        #endif
    }()

    private(set) var choice: Choice?
    private(set) var ownKeys: [CredentialService: String] = [:]
    /// The app's shared keys, by `CredentialService` raw value.
    private(set) var appSecrets: [String: String] = [:]
    /// Why the app's key couldn't be fetched, for the user.
    private(set) var appKeyProblem: String?

    @ObservationIgnored private let storage: CredentialStorage
    @ObservationIgnored private let client: AppKeyClient?
    @ObservationIgnored private let supportsOwnKeys: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let builtInKey: (CredentialService) -> String?
    @ObservationIgnored private let appKeysEnabled: @MainActor () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var isRefreshing = false

    init(storage: CredentialStorage, client: AppKeyClient?, supportsOwnKeys: Bool = true,
         defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         builtInKey: @escaping (CredentialService) -> String? = CredentialStore.infoPlistKey,
         appKeysEnabled: @escaping @MainActor () -> Bool = { AppConfigStore.shared.config?.appKeysEnabled ?? true },
         now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.client = client
        self.supportsOwnKeys = supportsOwnKeys
        self.defaults = defaults
        self.environment = environment
        self.builtInKey = builtInKey
        self.appKeysEnabled = appKeysEnabled
        self.now = now
        choice = defaults.string(forKey: Self.choiceKey).flatMap(Choice.init)
        for service in CredentialService.allCases {
            if let data = storage.read(account: service.rawValue), let key = String(data: data, encoding: .utf8) {
                ownKeys[service] = key
            }
        }
        appSecrets = client?.state?.secrets ?? [:]
    }

    /// The Info.plist value, ignoring an unset build setting.
    nonisolated static func infoPlistKey(for service: CredentialService) -> String? {
        usable(Bundle.main.object(forInfoDictionaryKey: service.infoKey) as? String)
    }

    private nonisolated static func usable(_ key: String?) -> String? {
        let key = key?.trimmingCharacters(in: .whitespaces)
        guard let key, !key.isEmpty, !key.hasPrefix("$("), !key.hasPrefix("YOUR_") else { return nil }
        return key
    }

    /// Whether this device can use the app's key: App Attest, which Mac apps
    /// don't have, and the remote config hasn't turned it off.
    var canUseAppKeys: Bool { (client?.isSupported ?? false) && appKeysEnabled() }

    func key(for service: CredentialService) -> String? {
        if let key = Self.usable(environment[service.environmentVariable]) { return key }
        if let key = ownKeys[service] { return key }
        if usesAppKey(for: service) { return appSecrets[service.rawValue] }
        return builtInKey(service)
    }

    /// Whether `service` is on the app's shared key, rather than one the user
    /// or a developer supplied.
    func usesAppKey(for service: CredentialService) -> Bool {
        Self.usable(environment[service.environmentVariable]) == nil && ownKeys[service] == nil
            && choice == .app && canUseAppKeys
    }

    /// Whether the user supplied the key in use for `service`, so only they
    /// can fix it.
    func usesOwnKey(for service: CredentialService) -> Bool {
        Self.usable(environment[service.environmentVariable]) == nil && ownKeys[service] != nil
    }

    /// The first launch asks, unless a key is already there.
    var needsChoice: Bool {
        supportsOwnKeys && choice == nil && ownKeys.isEmpty && key(for: .googleMaps) == nil
    }

    /// For the remote config's notices: "own" apps aren't spending the shared
    /// quota, so a notice about it doesn't apply to them.
    var keySource: String { choice == .own ? "own" : "app" }

    func choose(_ choice: Choice) {
        self.choice = choice
        defaults.set(choice.rawValue, forKey: Self.choiceKey)
        AppConfigStore.shared.reevaluate()
        if choice == .app { Task { await refreshAppKeys() } }
    }

    /// Saves the user's key, or removes it when nil or blank.
    func setOwnKey(_ key: String?, for service: CredentialService) throws {
        if let key = Self.usable(key) {
            try storage.write(Data(key.utf8), account: service.rawValue, synchronizable: true)
            ownKeys[service] = key
            if choice == nil { choose(.own) }
        } else {
            storage.delete(account: service.rawValue)
            ownKeys[service] = nil
        }
    }

    /// Fetches the app's keys if they're due. `force` is for a rejected key:
    /// it may have been rotated.
    func refreshAppKeys(force: Bool = false) async {
        guard let client, choice == .app, canUseAppKeys, !isRefreshing else { return }
        if let lastRefresh, now().timeIntervalSince(lastRefresh) < Self.minimumRefreshInterval { return }
        if !force, let state = client.state, now() < state.refreshAfter { return }
        lastRefresh = now()
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await client.update()
            appSecrets = client.state?.secrets ?? [:]
            appKeyProblem = nil
        } catch {
            print("[AlsoMaps] App key not refreshed: \(error.localizedDescription)")
            // A saved key keeps working, and the next attempt may succeed.
            if appSecrets.isEmpty { appKeyProblem = "The app's key isn't available right now. Try again later, or add your own." }
        }
    }
}
