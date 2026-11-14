#if !os(tvOS)
import SwiftUI

/// Searching Google for a place, as the user types, and fetching the one
/// they pick. See `PlacesClient` for how requests are billed.
@MainActor
@Observable
final class PlaceSearch {
    var query = ""
    private(set) var suggestions: [PlaceSuggestion] = []
    private(set) var problem: String?
    /// The suggestion whose place is being fetched.
    private(set) var choosing: PlaceSuggestion.ID?
    @ObservationIgnored private var session = UUID().uuidString

    /// Pause after a keystroke before asking for suggestions.
    private static let typingPause = Duration.milliseconds(250)

    var isSearching: Bool { !trimmedQuery.isEmpty }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var client: PlacesClient? {
        CredentialStore.shared.key(for: .googleMaps).map { PlacesClient(key: $0) }
    }

    /// Suggestions for the query, near `near`. Run per query, so a newer
    /// one cancels it.
    func suggest(near: GeoCoordinate?) async {
        let input = trimmedQuery
        guard !input.isEmpty else {
            suggestions = []
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
            problem = found.isEmpty ? "No places found." : nil
        } catch {
            guard !Task.isCancelled else { return }
            suggestions = []
            problem = error.localizedDescription
        }
    }

    /// The suggestion's place, or nil (with `problem` set) if it couldn't
    /// be fetched. Ends the session either way.
    func choose(_ suggestion: PlaceSuggestion) async -> Place? {
        guard choosing == nil, let client else { return nil }
        choosing = suggestion.id
        defer {
            choosing = nil
            session = UUID().uuidString
        }
        do {
            return try await client.place(for: suggestion, session: session)
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }
}

/// The saved places, or with a query, Google's suggestions for it.
struct PlacesList: View {
    var search: PlaceSearch
    /// Where to bias suggestions toward, read when they're requested so the
    /// list doesn't redraw as the camera moves.
    var near: () -> GeoCoordinate?
    var selectedID: String?
    var go: (Place) -> Void

    var body: some View {
        #if os(macOS)
        // A Mac List draws each button as a filled row; rows like a menu's,
        // highlighted under the pointer, suit a popover better.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { rows }
                .buttonStyle(MenuRowStyle())
                .padding(6)
        }
        .task(id: search.query) { await search.suggest(near: near()) }
        #else
        List { rows }
            .task(id: search.query) { await search.suggest(near: near()) }
        #endif
    }

    @ViewBuilder private var rows: some View {
        if search.isSearching {
            Section {
                if let problem = search.problem {
                    Text(problem)
                        .foregroundStyle(.secondary)
                        #if os(macOS)
                        .padding(8)
                        #endif
                }
                ForEach(search.suggestions) { suggestion in
                    Button {
                        Task {
                            if let place = await search.choose(suggestion) { go(place) }
                        }
                    } label: {
                        row(suggestion.name, detail: suggestion.detail,
                            isBusy: search.choosing == suggestion.id)
                    }
                }
            } footer: {
                if !search.suggestions.isEmpty {
                    GoogleMapsAttribution()
                        #if os(macOS)
                        .padding(8)
                        #endif
                }
            }
        } else {
            ForEach(PlaceLibrary.all) { place in
                Button { go(place) } label: {
                    row(place.name, isSelected: place.id == selectedID)
                }
            }
        }
    }

    private func row(_ name: String, detail: String? = nil, isSelected: Bool = false,
                     isBusy: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isBusy {
                ProgressView()
            } else if isSelected {
                Image(systemName: "checkmark")
                    .accessibilityLabel("Selected")
            }
        }
        .contentShape(Rectangle())
        #if !os(macOS)
        .foregroundStyle(.primary)
        #endif
    }
}

#if os(macOS)
/// A row like a menu item's: full width, highlighted under the pointer.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            let isHighlighted = isHovered || configuration.isPressed
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(isHighlighted ? Color.accentColor : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .onHover { isHovered = $0 }
        }
    }
}
#endif

/// Places search with its own field, for a popover from the Places button.
struct PlacesPanel: View {
    @State private var search = PlaceSearch()
    var near: () -> GeoCoordinate?
    var selectedID: String? = nil
    var go: (Place) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Places", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(chooseFirst)
                .padding()
            PlacesList(search: search, near: near, selectedID: selectedID, go: go)
        }
        .frame(width: 360, height: 440)
    }

    /// Return takes the first suggestion.
    private func chooseFirst() {
        guard let first = search.suggestions.first else { return }
        Task {
            if let place = await search.choose(first) { go(place) }
        }
    }
}

/// Google's attribution for Places content shown off the map: the logo,
/// which the app only has in white, so the name in light appearance.
struct GoogleMapsAttribution: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                Image("GoogleMapsLogo")
                    .accessibilityLabel("Google Maps")
            } else {
                Text("Google Maps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
