#if !os(tvOS)
import SwiftUI

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
                        search.choose(suggestion, then: go)
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
                Button {
                    search.cancelChoice()
                    go(place)
                } label: {
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
                .onSubmit { search.chooseFirst(then: go) }
                .padding()
            PlacesList(search: search, near: near, selectedID: selectedID, go: go)
        }
        .frame(width: 360, height: 440)
        .onDisappear { search.cancelChoice() }
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
