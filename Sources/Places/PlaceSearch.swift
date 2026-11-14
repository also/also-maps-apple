import Foundation
import Observation

/// Searching Google for a place, as the user types, and fetching the one
/// they pick. See `PlacesClient` for how requests are billed.
@MainActor
@Observable
final class PlaceSearch {
    var query = ""
    private(set) var suggestions: [PlaceSuggestion] = []
    /// The query `suggestions` are for. They stay up while the next
    /// query's are on the way, so Return checks this before taking one.
    private var suggestionsQuery: String?
    private(set) var problem: String?
    /// The suggestion whose place is being fetched.
    private(set) var choosing: PlaceSuggestion.ID?
    @ObservationIgnored private var session = UUID().uuidString
    /// Fetching the chosen suggestion's place. Choosing anything else, or
    /// closing the search, cancels it, so a slow answer can't move the map
    /// after the user has gone somewhere else.
    @ObservationIgnored private var lookup: Task<Void, Never>?

    /// Pause after a keystroke before asking for suggestions.
    private static let typingPause = Duration.milliseconds(250)

    var isSearching: Bool { !trimmedQuery.isEmpty }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The client for the key in use now, or nil without one.
    @ObservationIgnored private let makeClient: @MainActor () -> PlacesClient?
    private var client: PlacesClient? { makeClient() }

    init(client: @escaping @MainActor () -> PlacesClient? = {
        CredentialStore.shared.key(for: .googleMaps).map { PlacesClient(key: $0) }
    }) {
        makeClient = client
    }

    /// Suggestions for the query, near `near`. Run per query, so a newer
    /// one cancels it.
    func suggest(near: GeoCoordinate?) async {
        let input = trimmedQuery
        guard !input.isEmpty else {
            suggestions = []
            suggestionsQuery = nil
            problem = nil
            return
        }
        try? await Task.sleep(for: Self.typingPause)
        guard !Task.isCancelled else { return }
        guard let client else {
            suggestions = []
            problem = "Searching needs a Google Maps key. Add one in Keys."
            return
        }
        do {
            let found = try await client.autocomplete(input, near: near, session: session)
            guard !Task.isCancelled else { return }
            suggestions = found
            suggestionsQuery = input
            problem = found.isEmpty ? "No places found." : nil
        } catch {
            guard !Task.isCancelled else { return }
            suggestions = []
            suggestionsQuery = nil
            problem = error.localizedDescription
        }
    }

    /// Fetches the suggestion's place and hands it to `go`, unless
    /// something else is chosen first. Ends the session.
    func choose(_ suggestion: PlaceSuggestion, then go: @escaping (Place) -> Void) {
        cancelChoice()
        guard let client else { return }
        let session = session
        self.session = UUID().uuidString
        choosing = suggestion.id
        lookup = Task {
            do {
                let place = try await client.place(for: suggestion, session: session)
                guard !Task.isCancelled else { return }
                choosing = nil
                go(place)
            } catch {
                guard !Task.isCancelled else { return }
                choosing = nil
                problem = error.localizedDescription
            }
        }
    }

    /// Return: the first suggestion, if it's for the query in the field.
    func chooseFirst(then go: @escaping (Place) -> Void) {
        guard suggestionsQuery == trimmedQuery, let first = suggestions.first else { return }
        choose(first, then: go)
    }

    /// Drops a lookup in progress, for when the user goes elsewhere or
    /// closes the search.
    func cancelChoice() {
        lookup?.cancel()
        lookup = nil
        choosing = nil
    }
}
