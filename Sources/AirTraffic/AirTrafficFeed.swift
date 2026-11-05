import Foundation
import Observation

/// The circle asked about: around the area of interest, a little wider so
/// aircraft are known before they reach it, within limits that keep the
/// response small.
struct AirTrafficArea: Equatable {
    var centre: GeoCoordinate
    /// Metres.
    var radius: Double

    /// Aircraft this far out (metres) are fetched even for a small map, so
    /// approaches show before they arrive; and none further, however much
    /// streams, so a globe doesn't ask for a continent's traffic.
    static let minimumRadius = 15_000.0
    static let maximumRadius = 75_000.0
    /// How much wider than the area of interest.
    static let margin = 1.5

    /// For the area of interest of `streaming`.
    init(streaming: StreamingInputs) {
        self.init(centre: streaming.anchor.coordinate,
                  radius: min(max(streaming.streamingRadius * Self.margin, Self.minimumRadius), Self.maximumRadius))
    }

    init(centre: GeoCoordinate, radius: Double) {
        self.centre = centre
        self.radius = radius
    }
}

/// adsb.lol's v2 API: free, no key, data under the ODbL. Its point query
/// returns the aircraft within a radius (nautical miles, at most 250) of a
/// point. ALSOMAPS_AIR_TRAFFIC_URL replaces the URL with a template using
/// {lat}, {lon} and {radius_nm}, for another readsb-compatible API (e.g.
/// one serving the same ADS-B Exchange v2 format).
enum AirTrafficQuery {
    static let defaultTemplate = "https://api.adsb.lol/v2/point/{lat}/{lon}/{radius_nm}"
    /// ODbL §4.3 asks for notice of the database's source and licence
    /// wherever its data is shown.
    static let attribution = "Aircraft: adsb.lol (ODbL)"

    static var template: String {
        ProcessInfo.processInfo.environment["ALSOMAPS_AIR_TRAFFIC_URL"] ?? defaultTemplate
    }

    static func url(for area: AirTrafficArea, template: String = defaultTemplate) -> URL? {
        let nauticalMiles = min(max(Int((area.radius / 1852).rounded(.up)), 1), 250)
        let text = template
            .replacingOccurrences(of: "{lat}", with: String(format: "%.4f", area.centre.latitude))
            .replacingOccurrences(of: "{lon}", with: String(format: "%.4f", area.centre.longitude))
            .replacingOccurrences(of: "{radius_nm}", with: String(nauticalMiles))
        return URL(string: text)
    }
}

/// When to ask next. Every `interval` while answers come; after a failure,
/// twice as long each time up to `maximumInterval`, or as long as a 429's
/// Retry-After says if that's longer. A map that's moved more than half the
/// area's radius since the last request is asked about early, but never
/// sooner than `minimumInterval` after the last request, nor during a
/// back-off.
struct AirTrafficSchedule: Equatable {
    var interval = 10.0
    var minimumInterval = 5.0
    var maximumInterval = 120.0
    private(set) var failures = 0
    /// Device seconds.
    private(set) var lastRequest: TimeInterval?
    private(set) var nextRequest: TimeInterval = 0
    private(set) var lastArea: AirTrafficArea?

    enum Outcome: Equatable {
        case success
        case failure
        /// HTTP 429 (or 503), with Retry-After seconds if given.
        case rateLimited(retryAfter: Double?)
    }

    func isDue(at now: TimeInterval, area: AirTrafficArea) -> Bool {
        if now >= nextRequest { return true }
        guard failures == 0, let lastRequest, let lastArea, now - lastRequest >= minimumInterval else { return false }
        return GeoMath.distance(from: lastArea.centre, to: area.centre) > lastArea.radius / 2
    }

    mutating func requested(at now: TimeInterval, area: AirTrafficArea) {
        lastRequest = now
        lastArea = area
        // Until the answer: nothing else is due.
        nextRequest = .infinity
    }

    mutating func finished(_ outcome: Outcome, at now: TimeInterval) {
        switch outcome {
        case .success:
            failures = 0
            nextRequest = now + interval
        case .failure, .rateLimited:
            failures += 1
            var delay = min(interval * pow(2, Double(failures)), maximumInterval)
            if case let .rateLimited(retryAfter?) = outcome { delay = max(delay, min(retryAfter, 600)) }
            nextRequest = now + delay
        }
    }

    /// Turned off and on again: the first request goes at once.
    mutating func reset() { self = AirTrafficSchedule(interval: interval, minimumInterval: minimumInterval,
                                                      maximumInterval: maximumInterval) }
}

/// Polls for the aircraft around the map while it's on screen and the
/// feature is on, and hands each answer over. "On screen" is the host
/// calling `frame(area:now:)`: the map only ticks while it's being drawn,
/// so a closed or hidden map stops polling within a couple of seconds. Fails
/// open: an error keeps what's shown until it goes stale, and backs off.
@MainActor
@Observable
final class AirTrafficFeed {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    /// Polling, and the attribution showing.
    private(set) var isRunning = false
    /// Aircraft in the last answer, and why the last request failed, for
    /// the stats line.
    private(set) var aircraftCount = 0
    private(set) var lastError: String?

    /// Called with each answer and the device time it arrived.
    @ObservationIgnored var onSnapshot: ((AirTrafficSnapshot, TimeInterval) -> Void)?

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let template: String
    /// Device seconds, monotonic: the clock `frame(area:now:)` and the
    /// snapshots' arrival times are on.
    @ObservationIgnored let clock: () -> TimeInterval
    @ObservationIgnored private(set) var schedule = AirTrafficSchedule()
    @ObservationIgnored private var area: AirTrafficArea?
    @ObservationIgnored private var lastFrame: TimeInterval = -.infinity
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The map counts as hidden this long after its last frame, seconds.
    static let frameTimeout = 2.0

    static let defaultFetch: Fetch = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        return { try await session.data(for: $0) }
    }()

    /// Whether `start` begins polling by itself, checking once a second;
    /// tests call `pollIfDue` instead.
    @ObservationIgnored private let pollsInBackground: Bool

    init(fetch: @escaping Fetch = AirTrafficFeed.defaultFetch, template: String = AirTrafficQuery.template,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pollsInBackground: Bool = true) {
        self.fetch = fetch
        self.template = template
        self.clock = clock
        self.pollsInBackground = pollsInBackground
    }

    /// The map drew a frame showing `area`.
    func frame(area: AirTrafficArea, now: TimeInterval) {
        self.area = area
        lastFrame = now
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        schedule.reset()
        guard pollsInBackground else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollIfDue()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        task?.cancel()
        task = nil
        aircraftCount = 0
        lastError = nil
    }

    /// One request, if the map is showing and one is due.
    func pollIfDue() async {
        let now = clock()
        guard isRunning, let area, now - lastFrame < Self.frameTimeout, schedule.isDue(at: now, area: area),
              let url = AirTrafficQuery.url(for: area, template: template)
        else { return }
        schedule.requested(at: now, area: area)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let outcome: AirTrafficSchedule.Outcome
        do {
            let (data, response) = try await fetch(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if http.statusCode == 429 || http.statusCode == 503 {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    outcome = .rateLimited(retryAfter: retryAfter)
                } else {
                    outcome = .failure
                }
                lastError = "HTTP \(http.statusCode)"
            } else {
                let snapshot = try ADSBDecoder.decode(data)
                outcome = .success
                lastError = nil
                // Turned off while waiting: drop it.
                if isRunning {
                    aircraftCount = snapshot.reports.count
                    onSnapshot?(snapshot, clock())
                }
            }
        } catch {
            outcome = .failure
            lastError = error.localizedDescription
        }
        schedule.finished(outcome, at: clock())
        #if DEBUG
        if let lastError {
            print("[AlsoMaps] air traffic: \(lastError); next try in \(Int(schedule.nextRequest - clock())) s")
        }
        #endif
    }

    /// For the stats line.
    var summary: String {
        if let lastError { return "Aircraft: \(lastError)" }
        return "\(aircraftCount) aircraft"
    }
}
