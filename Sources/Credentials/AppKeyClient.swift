import CryptoKit
import DeviceCheck
import Foundation

/// The parts of App Attest the client uses, so tests can stand in for it.
protocol AppAttesting {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

extension DCAppAttestService: AppAttesting {}

/// Fetches the app's shared keys from the credentials API, proving with App
/// Attest that this is the real app on a real device. See
/// also-maps-site/docs/credentials-api.md. The API remembers nothing, so the
/// credential it issues is kept here with the keys.
@MainActor
final class AppKeyClient {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    struct State: Codable, Equatable {
        var keyID: String
        var credential: String
        var secrets: [String: String]
        var refreshAfter: Date
    }

    enum Failure: Error {
        /// The API refused the attestation, assertion or credential.
        case rejected
        case badResponse
    }

    private struct Challenge: Decodable { let challenge: String }

    private struct Issued: Decodable {
        var credential: String?
        let secrets: [String: String]
        let refreshAfter: String
    }

    private static let stateAccount = "app-key-state"
    /// A key Apple couldn't attest yet, to retry: it can only ever be attested
    /// once, and Apple asks that new keys are kept to a minimum.
    private static let pendingAccount = "app-key-pending"
    /// ALSOMAPS_CREDENTIALS_URL=<url> talks to another deployment.
    private static let defaultURL = URL(string: "https://maps.also.dev/api/credentials")!

    private(set) var state: State?
    /// Read once: the store asks every frame, on the main thread, and this
    /// goes to the system.
    let isSupported: Bool

    private let baseURL: URL
    private let attest: AppAttesting
    private let storage: CredentialStorage
    private let fetch: Fetch

    init(baseURL: URL, attest: AppAttesting, storage: CredentialStorage, fetch: @escaping Fetch) {
        self.baseURL = baseURL
        self.attest = attest
        isSupported = attest.isSupported
        self.storage = storage
        self.fetch = fetch
        if let data = storage.read(account: Self.stateAccount) {
            state = try? JSONDecoder().decode(State.self, from: data)
        }
    }

    static func live(storage: CredentialStorage) -> AppKeyClient {
        let session = URLSession(configuration: .ephemeral)
        let override = ProcessInfo.processInfo.environment["ALSOMAPS_CREDENTIALS_URL"].flatMap(URL.init(string:))
        return AppKeyClient(baseURL: override ?? defaultURL, attest: DCAppAttestService.shared,
                            storage: storage, fetch: { try await session.data(for: $0) })
    }

    /// Refreshes the keys, enrolling first if there's no usable credential.
    func update() async throws {
        if let state {
            do {
                try await refresh(state)
                return
            } catch Failure.rejected {
                // Expired, or the signing secret was rotated.
                clearState()
            } catch let error as DCError where error.code == .invalidKey {
                // Keys don't survive a reinstall or moving to a new device,
                // but the Keychain can.
                clearState()
            }
        }
        try await enroll()
    }

    private func refresh(_ state: State) async throws {
        let challenge: Challenge = try await post("challenge", ["purpose": "key", "credential": state.credential])
        let assertion = try await attest.generateAssertion(state.keyID, clientDataHash: Self.hash(challenge.challenge))
        let issued: Issued = try await post("key", ["credential": state.credential,
                                                    "challenge": challenge.challenge,
                                                    "assertion": assertion.base64EncodedString()])
        try save(issued, keyID: state.keyID, credential: state.credential)
    }

    private func enroll() async throws {
        let keyID: String
        if let pending = storage.read(account: Self.pendingAccount).flatMap({ String(data: $0, encoding: .utf8) }) {
            keyID = pending
        } else {
            keyID = try await attest.generateKey()
            try storage.write(Data(keyID.utf8), account: Self.pendingAccount, synchronizable: false)
        }
        let challenge: Challenge = try await post("challenge", ["purpose": "attest", "keyId": keyID])
        let attestation: Data
        do {
            attestation = try await attest.attestKey(keyID, clientDataHash: Self.hash(challenge.challenge))
        } catch let error as DCError where error.code == .serverUnavailable {
            throw error
        } catch {
            storage.delete(account: Self.pendingAccount)
            throw error
        }
        storage.delete(account: Self.pendingAccount)
        let issued: Issued = try await post("attest", ["challenge": challenge.challenge,
                                                       "attestation": attestation.base64EncodedString()])
        guard let credential = issued.credential else { throw Failure.badResponse }
        try save(issued, keyID: keyID, credential: credential)
    }

    private func save(_ issued: Issued, keyID: String, credential: String) throws {
        // JavaScript's toISOString, with milliseconds.
        let dates = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard let refreshAfter = try? dates.parse(issued.refreshAfter) else { throw Failure.badResponse }
        let state = State(keyID: keyID, credential: credential, secrets: issued.secrets, refreshAfter: refreshAfter)
        try storage.write(JSONEncoder().encode(state), account: Self.stateAccount, synchronizable: false)
        self.state = state
    }

    private func clearState() {
        state = nil
        storage.delete(account: Self.stateAccount)
    }

    /// The API signs the exact challenge string's UTF-8 bytes.
    private static func hash(_ challenge: String) -> Data {
        Data(SHA256.hash(data: Data(challenge.utf8)))
    }

    private func post<Response: Decodable>(_ action: String, _ body: [String: String]) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: action), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await fetch(request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.badResponse }
        if status == 401 { throw Failure.rejected }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
