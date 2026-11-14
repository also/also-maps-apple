import Foundation
import Testing

/// Answers like Places API (New): suggestions named after the input, and
/// details after a delay that depends on the place.
private final class SlowPlaces: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.withLock { _paths } }

    var client: PlacesClient {
        var client = PlacesClient(key: "test-key")
        client.fetch = { request in
            let path = request.url!.path
            self.lock.withLock { self._paths.append(path) }
            let body: String
            if path.hasSuffix("places:autocomplete") {
                let input = (try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["input"] as! String
                body = #"{"suggestions": [{"placePrediction": {"placeId": "\#(input)", "text": {"text": "\#(input)"}}}]}"#
            } else {
                try await Task.sleep(for: path.hasSuffix("slow") ? .milliseconds(300) : .milliseconds(10))
                body = #"{"location": {"latitude": 1, "longitude": 2}}"#
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        return client
    }
}

@MainActor
struct PlaceSearchTests {
    @Test func aLaterChoiceWinsOverASlowLookup() async throws {
        let places = SlowPlaces()
        let search = PlaceSearch(client: { places.client })
        var went: [String] = []
        search.choose(PlaceSuggestion(id: "slow", name: "Slow", detail: nil)) { went.append($0.name) }
        search.choose(PlaceSuggestion(id: "fast", name: "Fast", detail: nil)) { went.append($0.name) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(went == ["Fast"])
        #expect(search.choosing == nil)
    }

    @Test func goingElsewhereDropsALookup() async throws {
        let places = SlowPlaces()
        let search = PlaceSearch(client: { places.client })
        var went: [String] = []
        search.choose(PlaceSuggestion(id: "slow", name: "Slow", detail: nil)) { went.append($0.name) }
        search.cancelChoice()
        try await Task.sleep(for: .milliseconds(500))
        #expect(went.isEmpty)
        #expect(search.choosing == nil)
    }

    @Test func returnWaitsForTheQuerysOwnSuggestions() async throws {
        let places = SlowPlaces()
        let search = PlaceSearch(client: { places.client })
        var went: [String] = []
        search.query = "boston"
        await search.suggest(near: nil)
        #expect(search.suggestions.map(\.name) == ["boston"])

        // Boston's suggestions are still up while Paris's are on the way.
        search.query = "paris"
        search.chooseFirst { went.append($0.name) }
        #expect(search.choosing == nil)

        await search.suggest(near: nil)
        search.chooseFirst { went.append($0.name) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(went == ["paris"])
        #expect(places.paths.filter { $0.hasPrefix("/v1/places/") } == ["/v1/places/paris"])
    }
}
