import Foundation
import Testing

private let sanFrancisco = GeoCoordinate(latitude: 37.6189, longitude: -122.375)

struct AirTrafficAreaTests {
    private func inputs(radius: Double) -> StreamingInputs {
        StreamingInputs(anchor: StreamingAnchor(coordinate: sanFrancisco), streamingRadius: radius)
    }

    @Test func widensSmallMapsAndCapsBigOnes() {
        #expect(AirTrafficArea(streaming: inputs(radius: 600)).radius == AirTrafficArea.minimumRadius)
        #expect(AirTrafficArea(streaming: inputs(radius: 20_000)).radius == 30_000)
        #expect(AirTrafficArea(streaming: inputs(radius: 2_000_000)).radius == AirTrafficArea.maximumRadius)
    }

    @Test func asksForWholeNauticalMilesWithinTheAPIsLimit() {
        let url = AirTrafficQuery.url(for: AirTrafficArea(centre: sanFrancisco, radius: 15_000))
        #expect(url?.absoluteString == "https://api.adsb.lol/v2/point/37.6189/-122.3750/9")
        let huge = AirTrafficQuery.url(for: AirTrafficArea(centre: sanFrancisco, radius: 1e7),
                                       template: "http://localhost:8080/?circle={lat},{lon},{radius_nm}")
        #expect(huge?.absoluteString == "http://localhost:8080/?circle=37.6189,-122.3750,250")
    }
}

struct AirTrafficScheduleTests {
    private let area = AirTrafficArea(centre: sanFrancisco, radius: 20_000)

    @Test func pollsEveryIntervalWhileAnswersCome() {
        var schedule = AirTrafficSchedule()
        #expect(schedule.isDue(at: 0, area: area))
        schedule.requested(at: 0, area: area)
        #expect(!schedule.isDue(at: 1, area: area))  // Still waiting.
        schedule.finished(.success, at: 1)
        #expect(!schedule.isDue(at: 10.9, area: area))
        #expect(schedule.isDue(at: 11, area: area))
    }

    @Test func backsOffOnFailureUpToALimit() {
        var schedule = AirTrafficSchedule()
        var delays: [Double] = []
        for _ in 0..<6 {
            schedule.requested(at: 0, area: area)
            schedule.finished(.failure, at: 0)
            delays.append(schedule.nextRequest)
        }
        #expect(delays == [20, 40, 80, 120, 120, 120])
        schedule.requested(at: 0, area: area)
        schedule.finished(.success, at: 0)
        #expect(schedule.nextRequest == 10)
    }

    @Test func honoursRetryAfter() {
        var schedule = AirTrafficSchedule()
        schedule.requested(at: 0, area: area)
        schedule.finished(.rateLimited(retryAfter: 300), at: 0)
        #expect(schedule.nextRequest == 300)
        schedule.requested(at: 300, area: area)
        schedule.finished(.rateLimited(retryAfter: nil), at: 300)
        #expect(schedule.nextRequest == 340)
    }

    @Test func movingFarAsksEarlyButNotTooOften() {
        var schedule = AirTrafficSchedule()
        schedule.requested(at: 0, area: area)
        schedule.finished(.success, at: 0)
        let moved = AirTrafficArea(centre: GeoMath.destination(from: sanFrancisco, bearing: 0, distance: 15_000),
                                   radius: 20_000)
        #expect(!schedule.isDue(at: 4, area: moved))
        #expect(schedule.isDue(at: 5, area: moved))
        #expect(!schedule.isDue(at: 5, area: area))
        // Not during a back-off.
        schedule.requested(at: 5, area: area)
        schedule.finished(.failure, at: 5)
        #expect(!schedule.isDue(at: 20, area: moved))
    }
}

@MainActor
struct AirTrafficFeedTests {
    private let area = AirTrafficArea(centre: sanFrancisco, radius: 20_000)

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: status,
                        httpVersion: nil, headerFields: headers)!
    }

    @Test func pollsOnlyWhileTheMapIsDrawn() async {
        var time = 100.0
        var requests: [URL] = []
        let body = Data(#"{"ac": [{"hex": "abc123", "alt_baro": 1000, "lat": 37.6, "lon": -122.4, "seen_pos": 0}], "now": 0}"#.utf8)
        let ok = response(200)
        let feed = AirTrafficFeed(fetch: { request in
            requests.append(request.url!)
            return (body, ok)
        }, template: AirTrafficQuery.defaultTemplate, clock: { time }, pollsInBackground: false)
        var received: [(Int, TimeInterval)] = []
        feed.onSnapshot = { snapshot, at in received.append((snapshot.reports.count, at)) }
        feed.start()
        defer { feed.stop() }

        // No frame yet: nothing to ask about.
        await feed.pollIfDue()
        #expect(requests.isEmpty)

        feed.frame(area: area, now: time)
        await feed.pollIfDue()
        #expect(requests.map(\.absoluteString) == ["https://api.adsb.lol/v2/point/37.6189/-122.3750/11"])
        #expect(received.count == 1 && received[0] == (1, 100))
        #expect(feed.aircraftCount == 1)

        // Due again, but the map stopped drawing.
        time += 15
        await feed.pollIfDue()
        #expect(requests.count == 1)
        feed.frame(area: area, now: time)
        await feed.pollIfDue()
        #expect(requests.count == 2)
    }

    @Test func aRateLimitBacksOffAndKeepsRunning() async {
        var time = 0.0
        let limited = response(429, headers: ["Retry-After": "60"])
        let feed = AirTrafficFeed(fetch: { _ in (Data(), limited) },
                                  template: AirTrafficQuery.defaultTemplate, clock: { time },
                                  pollsInBackground: false)
        feed.start()
        defer { feed.stop() }
        feed.frame(area: area, now: time)
        await feed.pollIfDue()
        #expect(feed.lastError == "HTTP 429")
        #expect(feed.schedule.nextRequest == 60)
        #expect(feed.isRunning)
        time = 30
        #expect(!feed.schedule.isDue(at: time, area: area))
    }
}
