import Foundation
import Testing

/// Answers like Places API (New), recording what was asked.
private final class FakePlaces: @unchecked Sendable {
    var requests: [URLRequest] = []
    var status = 200
    var body = "{}"

    var client: PlacesClient {
        var client = PlacesClient(key: "test-key")
        client.fetch = { request in
            self.requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: self.status,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(self.body.utf8), response)
        }
        return client
    }

    func json(_ index: Int) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data()) as! [String: Any]
    }
}

private let eiffel = PlaceSuggestion(id: "ChIJ123", name: "Eiffel Tower", detail: "Paris, France")

struct PlacesClientTests {
    @Test func autocompleteSendsTheSessionAndBias() async throws {
        let fake = FakePlaces()
        fake.body = #"{"suggestions": []}"#
        _ = try await fake.client.autocomplete("eiffel", near: GeoCoordinate(latitude: 48.8, longitude: 2.3),
                                               session: "s1")
        let request = fake.requests[0]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://places.googleapis.com/v1/places:autocomplete")
        #expect(request.value(forHTTPHeaderField: "X-Goog-Api-Key") == "test-key")
        let body = try fake.json(0)
        #expect(body["input"] as? String == "eiffel")
        #expect(body["sessionToken"] as? String == "s1")
        let circle = (body["locationBias"] as? [String: Any])?["circle"] as? [String: Any]
        #expect(circle?["radius"] as? Double == 50_000)
        #expect((circle?["center"] as? [String: Double])?["latitude"] == 48.8)
    }

    @Test func autocompleteWithoutABiasSendsNone() async throws {
        let fake = FakePlaces()
        _ = try await fake.client.autocomplete("eiffel", near: nil, session: "s1")
        #expect(try fake.json(0)["locationBias"] == nil)
    }

    @Test func suggestionsAreOnlyPlaces() async throws {
        let fake = FakePlaces()
        fake.body = #"""
        {"suggestions": [
          {"placePrediction": {"place": "places/ChIJ123", "placeId": "ChIJ123",
            "text": {"text": "Eiffel Tower, Paris, France"},
            "structuredFormat": {"mainText": {"text": "Eiffel Tower"}, "secondaryText": {"text": "Paris, France"}}}},
          {"queryPrediction": {"text": {"text": "eiffel tower restaurants"}}},
          {"placePrediction": {"placeId": "ChIJ456", "text": {"text": "Eiffel"}}}
        ]}
        """#
        let suggestions = try await fake.client.autocomplete("eiffel", near: nil, session: "s1")
        #expect(suggestions == [eiffel, PlaceSuggestion(id: "ChIJ456", name: "Eiffel", detail: nil)])
    }

    @Test func detailsAskForEssentialsFieldsOnly() async throws {
        let fake = FakePlaces()
        fake.body = #"""
        {"location": {"latitude": 48.8584, "longitude": 2.2945},
         "viewport": {"low": {"latitude": 48.857, "longitude": 2.292}, "high": {"latitude": 48.860, "longitude": 2.297}}}
        """#
        let place = try await fake.client.place(for: eiffel, session: "s1")
        let request = fake.requests[0]
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://places.googleapis.com/v1/places/ChIJ123?sessionToken=s1")
        #expect(request.value(forHTTPHeaderField: "X-Goog-FieldMask") == "location,viewport")
        #expect(place.name == "Eiffel Tower")
        #expect(place.latitude == 48.8584)
        #expect(place.longitude == 2.2945)
        #expect(place.radius == 250)
    }

    @Test func aPlaceWithoutALocationFails() async throws {
        let fake = FakePlaces()
        await #expect(throws: PlacesClient.Failure.noLocation) {
            try await fake.client.place(for: eiffel, session: "s1")
        }
    }

    @Test func aRefusedKeyKeepsGooglesMessage() async throws {
        let fake = FakePlaces()
        fake.status = 403
        fake.body = #"{"error": {"code": 403, "message": "Places API (New) has not been used", "status": "PERMISSION_DENIED"}}"#
        await #expect(throws: PlacesClient.Failure.refused(status: 403, message: "Places API (New) has not been used")) {
            try await fake.client.autocomplete("eiffel", near: nil, session: "s1")
        }
    }

    @Test func radiusIsHalfTheViewportsLargerSide() {
        // About 111 km north to south and 79 km east to west at 45°.
        let viewport = PlaceDetails.Viewport(low: .init(latitude: 44.5, longitude: 0),
                                             high: .init(latitude: 45.5, longitude: 1))
        #expect(abs(PlacesClient.radius(of: viewport) - 55_597) < 10)
        #expect(PlacesClient.radius(of: nil) == PlacesClient.defaultRadius)
    }

    @Test func radiusSpansTheAntimeridian() {
        // Fiji's viewport crosses 180°: 2° wide, not 358°.
        let viewport = PlaceDetails.Viewport(low: .init(latitude: -0.5, longitude: 179),
                                             high: .init(latitude: 0.5, longitude: -179))
        #expect(abs(PlacesClient.radius(of: viewport) - 111_195) < 10)
    }

    @Test func radiusStaysInRange() {
        let tiny = PlaceDetails.Viewport(low: .init(latitude: 0, longitude: 0),
                                         high: .init(latitude: 0.0001, longitude: 0.0001))
        let huge = PlaceDetails.Viewport(low: .init(latitude: -80, longitude: -170),
                                         high: .init(latitude: 80, longitude: 170))
        #expect(PlacesClient.radius(of: tiny) == PlacesClient.radiusRange.lowerBound)
        #expect(PlacesClient.radius(of: huge) == PlacesClient.radiusRange.upperBound)
    }
}
