#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

/// The saved places, or with a query, Google's suggestions for it.
struct PlacesList: View {
    var search: PlaceSearch
    /// Where to bias suggestions toward, read when they're requested so the
    /// list doesn't redraw as the camera moves.
    var near: () -> GeoCoordinate?
    var selectedID: String?
    var go: (Place) -> Void
    @State private var renaming: Place?
    @State private var newName = ""

    var body: some View {
        content
            .alert("Rename Place", isPresented: Binding(get: { renaming != nil },
                                                       set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { place in
                TextField("Name", text: $newName)
                Button("Rename") { PlaceStore.shared.rename(place.id, to: newName) }
                Button("Cancel", role: .cancel) {}
            }
    }

    @ViewBuilder private var content: some View {
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
            let store = PlaceStore.shared
            if !store.myMap.isEmpty {
                section("My Map") {
                    ForEach(store.myMap) { place in
                        placeButton(place)
                            .contextMenu {
                                Button("Rename…", systemImage: "pencil") {
                                    newName = place.name
                                    renaming = place
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    store.remove(place.id)
                                }
                            }
                    }
                }
            }
            if let imported = store.imported {
                section(imported.name) {
                    ForEach(imported.places) { placeButton($0) }
                }
            }
            // The built-in and remote config's places come after the user's
            // own, under their own heading once there are any.
            section(store.myMap.isEmpty && store.imported == nil ? nil : "Suggestions") {
                ForEach(PlaceLibrary.all) { placeButton($0) }
            }
        }
    }

    private func placeButton(_ place: Place) -> some View {
        Button {
            search.cancelChoice()
            go(place)
        } label: {
            row(place.name, isSelected: place.id == selectedID)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        if let title {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
        }
        content()
        #else
        Section {
            content()
        } header: {
            if let title { Text(title) }
        }
        #endif
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
/// The field is there only while the map shows Google's tiles. Below the
/// list, place files: importing one, sharing My Map.
struct PlacesPanel: View {
    @State private var search = PlaceSearch()
    @State private var importing = false
    @State private var importProblem: String?
    var searchesGoogle: Bool
    var near: () -> GeoCoordinate?
    var selectedID: String? = nil
    var go: (Place) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if searchesGoogle {
                TextField("Search Places", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { search.chooseFirst(then: go) }
                    .padding()
            }
            PlacesList(search: search, near: near, selectedID: selectedID, go: go)
            fileActions
        }
        .frame(width: 360, height: 440)
        .onChange(of: searchesGoogle, initial: true) { search.searchesGoogle = $1 }
        .onDisappear { search.cancelChoice() }
    }
}

extension PlacesPanel {
    @ViewBuilder fileprivate var fileActions: some View {
        let store = PlaceStore.shared
        VStack(alignment: .leading, spacing: 8) {
            if let importProblem {
                Text(importProblem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Import…", systemImage: "square.and.arrow.down") { importing = true }
                if !store.myMap.isEmpty {
                    ShareLink(item: store.myMapFile) {
                        Label("Share My Map", systemImage: "square.and.arrow.up")
                    }
                }
                Spacer()
                if let imported = store.imported {
                    Button("Remove \(imported.name)", systemImage: "xmark.circle") {
                        store.removeImported()
                    }
                    .labelStyle(.iconOnly)
                    .help("Remove \(imported.name)")
                }
            }
        }
        .padding()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.alsoMapsPlaces, .geoJSON]) { result in
            do {
                try store.importFile(result.get())
                importProblem = nil
            } catch {
                importProblem = error.localizedDescription
            }
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
