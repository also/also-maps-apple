import Foundation

/// A place Autocomplete suggests: its name and the rest of its address.
struct PlaceSuggestion: Identifiable, Hashable {
    /// The Google place ID.
    let id: String
    let name: String
    let detail: String?
}

/// Place search with Places API (New), over REST so it works on every
/// platform. Autocomplete runs as the user types and Place Details runs for
/// the pick, in one session: a session that ends in Place Details makes its
/// Autocomplete requests free. Details asks only for `location` and
/// `viewport`, which are Essentials; the name comes from the suggestion,
/// since `displayName` would make the request Pro.
struct PlacesClient {
    enum Failure: LocalizedError, Equatable {
        /// The key was refused, or doesn't have Places API (New).
        case refused(status: Int, message: String?)
        case failed(status: Int, message: String?)
        case noLocation

        var errorDescription: String? {
            switch self {
            case .refused(let status, let message):
                "This Google Maps key can't use Places API (New) (HTTP \(status)). Enable the API for the key's project, and allow it in the key's API restrictions."
                    + (message.map { "\n\n\($0)" } ?? "")
            case .failed(let status, let message):
                message ?? "Place search failed (HTTP \(status))."
            case .noLocation:
                "Google didn't give a location for that place."
            }
        }
    }

    static let baseURL = URL(string: "https://places.googleapis.com/v1/")!
    /// The largest `locationBias` circle Autocomplete accepts.
    static let biasRadius = 50_000.0
    /// Framing limits for a place's viewport, as a view half-width in meters.
    static let radiusRange = 250.0...2_000_000.0
    /// For a place without a viewport.
    static let defaultRadius = 600.0

    let key: String
    var fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    /// Places matching `input`, nearer `near` first. Queries ("pizza near
    /// me") aren't suggested: only places can be framed.
    func autocomplete(_ input: String, near: GeoCoordinate?, session: String) async throws -> [PlaceSuggestion] {
        var body: [String: Any] = ["input": input, "sessionToken": session]
        if let near {
            body["locationBias"] = ["circle": [
                "center": ["latitude": near.latitude, "longitude": near.longitude],
                "radius": Self.biasRadius,
            ]]
        }
        var request = request(Self.baseURL.appending(path: "places:autocomplete"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response: AutocompleteResponse = try await send(request)
        return (response.suggestions ?? []).compactMap(\.placePrediction).map {
            PlaceSuggestion(id: $0.placeId,
                            name: $0.structuredFormat?.mainText.text ?? $0.text.text,
                            detail: $0.structuredFormat?.secondaryText?.text)
        }
    }

    /// The suggested place, framed by its viewport. Ends `session`.
    func place(for suggestion: PlaceSuggestion, session: String) async throws -> Place {
        var components = URLComponents(url: Self.baseURL.appending(path: "places/\(suggestion.id)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sessionToken", value: session)]
        var request = request(components.url!)
        request.setValue("location,viewport", forHTTPHeaderField: "X-Goog-FieldMask")
        let details: PlaceDetails = try await send(request)
        guard let location = details.location else { throw Failure.noLocation }
        return Place(id: "google:\(suggestion.id)", name: suggestion.name,
                     latitude: location.latitude, longitude: location.longitude,
                     radius: Self.radius(of: details.viewport))
    }

    /// Half the viewport's larger side, in meters, within `radiusRange`.
    static func radius(of viewport: PlaceDetails.Viewport?) -> Double {
        guard let viewport else { return defaultRadius }
        let meanRadius = 6_371_008.8
        let degrees = Double.pi / 180
        let north = (viewport.high.latitude - viewport.low.latitude) * degrees * meanRadius
        // A viewport across the antimeridian has its low longitude east of its high one.
        var span = viewport.high.longitude - viewport.low.longitude
        if span < 0 { span += 360 }
        let middle = (viewport.high.latitude + viewport.low.latitude) / 2
        let east = span * degrees * meanRadius * cos(middle * degrees)
        let radius = max(north, east) / 2
        return min(max(radius, radiusRange.lowerBound), radiusRange.upperBound)
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        // Keys restricted to this app need this, as tile requests send it.
        request.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
            throw [401, 403].contains(status)
                ? Failure.refused(status: status, message: message)
                : Failure.failed(status: status, message: message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

// MARK: Responses

struct PlaceDetails: Decodable {
    struct LatLng: Decodable {
        var latitude: Double
        var longitude: Double
    }

    struct Viewport: Decodable {
        var low: LatLng
        var high: LatLng
    }

    var location: LatLng?
    var viewport: Viewport?
}

private struct AutocompleteResponse: Decodable {
    struct Suggestion: Decodable {
        var placePrediction: PlacePrediction?
    }

    struct PlacePrediction: Decodable {
        var placeId: String
        var text: Text
        var structuredFormat: StructuredFormat?
    }

    struct StructuredFormat: Decodable {
        var mainText: Text
        var secondaryText: Text?
    }

    struct Text: Decodable {
        var text: String
    }

    var suggestions: [Suggestion]?
}

private struct ErrorResponse: Decodable {
    struct Body: Decodable {
        var message: String?
    }

    var error: Body
}
