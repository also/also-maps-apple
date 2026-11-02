import DeviceCheck
import Foundation
import Testing

private final class MemoryStorage: CredentialStorage {
    var items: [String: Data] = [:]
    func read(account: String) -> Data? { items[account] }
    func write(_ data: Data, account: String, synchronizable: Bool) throws { items[account] = data }
    func delete(account: String) { items[account] = nil }
}

private final class FakeAttest: AppAttesting {
    var isSupported = true
    var generated = 0
    var attested: [String] = []
    var assertions = 0
    var attestError: Error?
    var assertionError: Error?

    func generateKey() async throws -> String {
        generated += 1
        return "key-\(generated)"
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if let attestError { throw attestError }
        attested.append(keyId)
        return Data("attestation".utf8)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if let assertionError { throw assertionError }
        assertions += 1
        return Data("assertion".utf8)
    }
}

/// Answers like the credentials API, with what the tests choose.
private final class FakeAPI {
    var requests: [String] = []
    var status: [String: Int] = [:]
    var googleKey = "google-1"

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let action = request.url!.lastPathComponent
        requests.append(action)
        let body: String = switch action {
        case "challenge": #"{"challenge": "signed.jwt.value", "expiresIn": 120}"#
        case "attest": issued(credential: #""credential": "credential-1", "credentialExpiresIn": 15552000,"#)
        default: issued(credential: "")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status[action] ?? 200,
                                       httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    /// The API's dates have milliseconds, as JavaScript's toISOString does.
    private func issued(credential: String) -> String {
        #"{\#(credential) "secrets": {"googleMaps": "\#(googleKey)"}, "refreshAfter": "2027-01-02T03:04:05.678Z"}"#
    }
}

@MainActor
struct AppKeyClientTests {
    private let storage = MemoryStorage()
    private let attest = FakeAttest()
    private let api = FakeAPI()

    private func client() -> AppKeyClient {
        let api = api
        return AppKeyClient(baseURL: URL(string: "https://example.test/api/credentials")!, attest: attest,
                            storage: storage, fetch: { try await api.fetch($0) })
    }

    @Test func enrollsOnceThenRefreshesWithAssertions() async throws {
        let first = self.client()
        try await first.update()
        #expect(attest.attested == ["key-1"])
        #expect(api.requests == ["challenge", "attest"])
        #expect(first.state?.secrets == ["googleMaps": "google-1"])
        #expect(first.state?.credential == "credential-1")
        #expect(first.state?.refreshAfter == ISO8601DateFormatter().date(from: "2027-01-02T03:04:05Z")! + 0.678)

        api.googleKey = "google-2"
        api.requests = []
        let next = self.client()
        #expect(next.state?.keyID == "key-1")
        try await next.update()
        #expect(api.requests == ["challenge", "key"])
        #expect(attest.attested.count == 1)
        #expect(attest.assertions == 1)
        #expect(next.state?.secrets == ["googleMaps": "google-2"])
        #expect(next.state?.credential == "credential-1")
    }

    @Test func aRejectedCredentialEnrollsAgain() async throws {
        let client = self.client()
        try await client.update()
        api.status["key"] = 401
        try await client.update()
        #expect(attest.attested == ["key-1", "key-2"])
        #expect(client.state?.keyID == "key-2")
    }

    @Test func aLostKeyEnrollsAgain() async throws {
        let client = self.client()
        try await client.update()
        attest.assertionError = DCError(.invalidKey)
        try await client.update()
        #expect(attest.attested == ["key-1", "key-2"])
    }

    @Test func anOutageKeepsWhatWeHave() async throws {
        let client = self.client()
        try await client.update()
        api.status["key"] = 503
        await #expect(throws: (any Error).self) { try await client.update() }
        #expect(client.state?.keyID == "key-1")
        #expect(attest.attested.count == 1)
    }

    @Test func serverUnavailableRetriesTheSameKey() async throws {
        let client = self.client()
        attest.attestError = DCError(.serverUnavailable)
        await #expect(throws: (any Error).self) { try await client.update() }
        attest.attestError = nil
        try await client.update()
        #expect(attest.generated == 1)
        #expect(attest.attested == ["key-1"])
    }

    @Test func otherAttestErrorsDiscardTheKey() async throws {
        let client = self.client()
        attest.attestError = DCError(.invalidInput)
        await #expect(throws: (any Error).self) { try await client.update() }
        attest.attestError = nil
        try await client.update()
        #expect(attest.attested == ["key-2"])
    }
}

@MainActor
struct CredentialStoreTests {
    private let storage = MemoryStorage()
    private let attest = FakeAttest()
    private let api = FakeAPI()
    private let defaults = UserDefaults(suiteName: UUID().uuidString)!

    private func store(environment: [String: String] = [:], builtIn: String? = nil, enabled: Bool = true,
                       keySourceChanged: @escaping @MainActor () -> Void = {},
                       now: @escaping () -> Date = { .distantPast }) -> CredentialStore {
        let api = api
        let client = AppKeyClient(baseURL: URL(string: "https://example.test")!, attest: attest,
                                  storage: storage, fetch: { try await api.fetch($0) })
        return CredentialStore(storage: storage, client: client, defaults: defaults, environment: environment,
                               builtInKey: { _ in builtIn }, appKeysEnabled: { enabled },
                               keySourceChanged: keySourceChanged, now: now)
    }

    private func stored(_ choice: CredentialStore.Choice) {
        defaults.set(choice.rawValue, forKey: "KeyChoice")
    }

    @Test func asksOnlyWithNoKeyAndNoChoice() throws {
        #expect(store().needsChoice)
        #expect(!store(builtIn: "built-in").needsChoice)
        #expect(!store(environment: ["GOOGLE_MAPS_API_KEY": "env"]).needsChoice)
        stored(.own)
        #expect(!store().needsChoice)
    }

    @Test func aSavedKeyAnswersTheQuestion() throws {
        storage.items["googleMaps"] = Data("mine".utf8)
        #expect(!store().needsChoice)
    }

    @Test func precedence() async throws {
        stored(.app)
        var store = self.store(builtIn: "built-in")
        await store.refreshAppKeys()
        #expect(store.key(for: .googleMaps) == "google-1")
        #expect(store.usesAppKey(for: .googleMaps))

        storage.items["googleMaps"] = Data("mine".utf8)
        store = self.store(builtIn: "built-in")
        #expect(store.key(for: .googleMaps) == "mine")
        #expect(store.usesOwnKey(for: .googleMaps))
        #expect(!store.usesAppKey(for: .googleMaps))

        store = self.store(environment: ["GOOGLE_MAPS_API_KEY": "env"], builtIn: "built-in")
        #expect(store.key(for: .googleMaps) == "env")
        #expect(!store.usesOwnKey(for: .googleMaps))
    }

    @Test func ownKeysOnlyNeverTouchTheAppKey() async {
        stored(.own)
        let store = self.store()
        await store.refreshAppKeys(force: true)
        #expect(api.requests.isEmpty)
        #expect(store.key(for: .googleMaps) == nil)
    }

    @Test func noAppKeyWithoutAppAttest() async {
        stored(.app)
        attest.isSupported = false
        let store = self.store(builtIn: "built-in")
        #expect(!store.canUseAppKeys)
        await store.refreshAppKeys()
        #expect(api.requests.isEmpty)
        #expect(store.key(for: .googleMaps) == "built-in")
    }

    @Test func theRemoteConfigCanTurnTheAppKeyOff() async {
        stored(.app)
        await store().refreshAppKeys()
        let store = self.store(enabled: false)
        #expect(store.appSecrets["googleMaps"] == "google-1")
        #expect(store.key(for: .googleMaps) == nil)
    }

    @Test func refreshesOnlyWhenDueUnlessForced() async {
        stored(.app)
        var time = ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!
        let store = self.store(now: { time })
        await store.refreshAppKeys()
        api.requests = []
        api.googleKey = "google-2"

        time += 120
        await store.refreshAppKeys()
        #expect(api.requests.isEmpty)

        await store.refreshAppKeys(force: true)
        #expect(store.key(for: .googleMaps) == "google-2")
    }

    @Test func aRejectedKeyDoesNotRefreshEveryFrame() async {
        stored(.app)
        var time = ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!
        let store = self.store(now: { time })
        await store.refreshAppKeys()
        api.requests = []
        await store.refreshAppKeys(force: true)
        #expect(api.requests.isEmpty)
        time += 61
        await store.refreshAppKeys(force: true)
        #expect(!api.requests.isEmpty)
    }

    @Test func anOwnKeyLiftsABlockOnTheSharedKey() async throws {
        stored(.app)
        var config: AppConfigStore?
        let credentials = store(keySourceChanged: { config?.reevaluate() })
        let notice = #"{"id": "kill", "severity": "blocking", "title": "T", "body": "B", "keySource": "app"}"#
        let url = URL(string: "https://example.test/config.json")!
        config = AppConfigStore(url: url, cacheFile: nil, defaults: defaults, fetch: { _ in
            (Data(#"{"notices": [\#(notice)]}"#.utf8),
             HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, keySource: { credentials.keySource })
        await config?.refresh()
        #expect(config?.blocking?.id == "kill")

        try credentials.setOwnKey("mine", for: .googleMaps)
        #expect(credentials.choice == .app)
        #expect(credentials.keySource == "own")
        #expect(config?.blocking == nil)

        try credentials.setOwnKey(nil, for: .googleMaps)
        #expect(config?.blocking?.id == "kill")
    }

    @Test func anOwnCesiumTokenLeavesGoogleOnTheSharedKey() throws {
        stored(.app)
        let store = self.store()
        try store.setOwnKey("mine", for: .cesiumIon)
        #expect(store.keySource == "app")
    }

    @Test func failedFirstFetchesBackOff() async {
        stored(.app)
        api.status["challenge"] = 503
        var time = ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!
        let store = self.store(now: { time })
        #expect(store.appKeyRetryDelay == 0)
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            await store.refreshAppKeys()
            delays.append(store.appKeyRetryDelay)
            time += delays.last!
        }
        #expect(delays == [65, 130, 260, 520, 1040, 2080, 3600, 3600])

        api.status = [:]
        await store.refreshAppKeys()
        #expect(store.appKeyFailures == 0)
        #expect(store.appKeyRetryDelay == 0)
    }

    @Test func aFailedRefreshWithAKeyDoesNotBackOff() async {
        stored(.app)
        let store = self.store()
        await store.refreshAppKeys()
        api.status["key"] = 503
        await store.refreshAppKeys(force: true)
        #expect(store.appKeyFailures == 0)
        #expect(store.key(for: .googleMaps) == "google-1")
    }

    @Test func aFailedFirstFetchExplainsItself() async {
        stored(.app)
        api.status["challenge"] = 503
        let store = self.store()
        await store.refreshAppKeys()
        #expect(store.appKeyProblem != nil)
    }
}

struct KeychainStorageTests {
    @Test func roundTrips() throws {
        let storage = KeychainStorage()
        let account = "test-\(UUID().uuidString)"
        defer { storage.delete(account: account) }
        #expect(storage.read(account: account) == nil)
        try storage.write(Data("one".utf8), account: account, synchronizable: false)
        try storage.write(Data("two".utf8), account: account, synchronizable: false)
        #expect(storage.read(account: account) == Data("two".utf8))
        storage.delete(account: account)
        #expect(storage.read(account: account) == nil)
    }
}
