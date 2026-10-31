import Foundation
import Observation

/// The remote config, kept fresh in the background. Launch never waits for it:
/// the app starts from the last good copy, or the bundled places if there's
/// none. Every failure leaves that in place, so an outage or a bad file can't
/// stop the app (it fails open).
@MainActor
@Observable
final class AppConfigStore {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    /// Published from the also-maps-site repository.
    private static let defaultURL = URL(string: "https://maps.also.dev/config/v1.json")!
    private static let dismissedKey = "DismissedNotices"
    /// Windows each refresh, so this spaces out their requests.
    private static let minimumFetchInterval: TimeInterval = 30

    /// ALSOMAPS_CONFIG_URL=<url> reads another file, http(s) or file, without
    /// touching the saved copy.
    static let shared: AppConfigStore = {
        let session = URLSession(configuration: .ephemeral)
        let fetch: Fetch = { try await session.data(for: $0) }
        if let override = ProcessInfo.processInfo.environment["ALSOMAPS_CONFIG_URL"],
           let url = URL(string: override) {
            return AppConfigStore(url: url, cacheFile: nil, fetch: fetch, keySource: { CredentialStore.shared.keySource })
        }
        return AppConfigStore(url: defaultURL, cacheFile: defaultCacheFile, fetch: fetch,
                              keySource: { CredentialStore.shared.keySource })
    }()

    /// Caches, the only local storage tvOS keeps, so it's the same everywhere.
    /// If the system clears it, the next fetch restores it.
    private static var defaultCacheFile: URL {
        // Unsandboxed builds share ~/Library/Caches, so namespace by bundle.
        URL.cachesDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "AlsoMaps", directoryHint: .isDirectory)
            .appending(path: "config.json", directoryHint: .notDirectory)
    }

    private(set) var config: AppConfig?
    /// The notice stopping the app, if any.
    private(set) var blocking: Notice?
    /// The next notice to show, if any.
    private(set) var notice: Notice?
    private(set) var isRefreshing = false

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let cacheFile: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let platform: String
    @ObservationIgnored private let version: AppVersion
    @ObservationIgnored private let keySource: () -> String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastFetch: Date?

    init(url: URL, cacheFile: URL?, defaults: UserDefaults = .standard, fetch: @escaping Fetch,
         platform: String = AppPlatform.current, version: AppVersion = .current,
         keySource: @escaping () -> String = { "app" },
         now: @escaping () -> Date = Date.init) {
        self.url = url
        self.cacheFile = cacheFile
        self.defaults = defaults
        self.fetch = fetch
        self.platform = platform
        self.version = version
        self.keySource = keySource
        self.now = now
        if let cacheFile, let data = try? Data(contentsOf: cacheFile) {
            config = try? AppConfig.decode(data)
        }
        evaluate()
    }

    /// Fetches the config, unless that happened moments ago. `force` is for
    /// someone waiting on the answer.
    func refresh(force: Bool = false) async {
        // Notices may have expired since the last fetch, even if this one fails.
        evaluate()
        guard !isRefreshing else { return }
        if !force, let lastFetch, now().timeIntervalSince(lastFetch) < Self.minimumFetchInterval { return }
        lastFetch = now()
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await fetch(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            config = try AppConfig.decode(data)
            evaluate()
            if let cacheFile {
                try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: cacheFile, options: .atomic)
            }
        } catch {
            print("[AlsoMaps] Config not refreshed: \(error.localizedDescription)")
        }
    }

    /// Stops showing `notice`, for good.
    func dismiss(_ notice: Notice) {
        defaults.set(dismissedIDs.union([notice.id]).sorted(), forKey: Self.dismissedKey)
        evaluate()
    }

    private var dismissedIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    /// The key source changed, so different notices may apply.
    func reevaluate() {
        evaluate()
    }

    private func evaluate() {
        let source = keySource()
        let applicable = (config?.notices ?? []).filter {
            $0.applies(platform: platform, version: version, keySource: source, now: now())
        }
        let dismissed = dismissedIDs
        blocking = applicable.first { $0.severity == .blocking }
        notice = applicable.first { $0.severity == .info && !dismissed.contains($0.id) }
    }
}
