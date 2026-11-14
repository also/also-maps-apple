#if !os(tvOS)
import SwiftUI

/// Renaming, deleting and reordering My Map's places, the way each platform
/// edits a list. Its own window on visionOS and the Mac, a sheet on iPhone.
///
/// - Mac: a selectable list. Return or double-click renames the selected
///   place in its row; Delete (or Edit > Delete) and the − button delete
///   the selection; rows drag to reorder.
/// - iPhone, visionOS: Edit puts the list in edit mode, for deleting and
///   reordering; rows swipe to delete or rename.
/// - Everywhere: a place's context menu renames or deletes it.
struct MyMapEditor: View {
    static let windowID = "my-map"

    private var store: PlaceStore { .shared }
    @State private var selection = Set<Place.ID>()
    /// The place whose name is being edited (Mac: in its row; elsewhere: in
    /// an alert), and the name so far.
    @State private var renaming: Place.ID?
    @State private var newName = ""
    @FocusState private var renameFocused: Bool
    #if !os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            list
            Divider()
            HStack(spacing: 0) {
                Button("Delete", systemImage: "minus") { delete(selection) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(width: 24, height: 20)
                    .disabled(selection.isEmpty)
                    .help("Delete the selected places")
                Spacer()
            }
            .padding(4)
        }
        .frame(minWidth: 280, minHeight: 240)
        #else
        NavigationStack {
            list
                .navigationTitle("My Map")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { EditButton() }
                    #if os(iOS)
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    #endif
                }
                .alert("Rename Place", isPresented: Binding(get: { renaming != nil },
                                                           set: { if !$0 { renaming = nil } })) {
                    TextField("Name", text: $newName)
                    Button("Rename") { commitRename() }
                    Button("Cancel", role: .cancel) {}
                }
        }
        #endif
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(store.myMap) { place in
                row(place)
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") { beginRename(place) }
                        Button("Delete", systemImage: "trash", role: .destructive) { delete([place.id]) }
                    }
                    #if !os(macOS)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete([place.id]) }
                        Button("Rename", systemImage: "pencil") { beginRename(place) }
                    }
                    #endif
            }
            .onDelete { offsets in delete(Set(offsets.map { store.myMap[$0].id })) }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
        }
        .overlay {
            if store.myMap.isEmpty {
                ContentUnavailableView("No Places", systemImage: "star",
                                       description: Text("Places you save to My Map appear here."))
            }
        }
        #if os(macOS)
        .onDeleteCommand { delete(selection) }
        .onKeyPress(.return) {
            guard renaming == nil, selection.count == 1, let id = selection.first,
                  let place = store.myMap.first(where: { $0.id == id }) else { return .ignored }
            beginRename(place)
            return .handled
        }
        #endif
    }

    @ViewBuilder
    private func row(_ place: Place) -> some View {
        #if os(macOS)
        if renaming == place.id {
            TextField("Name", text: $newName)
                .focused($renameFocused)
                .onSubmit(commitRename)
                .onExitCommand { renaming = nil }
                .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
        } else {
            Text(place.name)
                .onTapGesture(count: 2) { beginRename(place) }
        }
        #else
        Text(place.name)
        #endif
    }

    private func beginRename(_ place: Place) {
        newName = place.name
        renaming = place.id
        #if os(macOS)
        selection = [place.id]
        renameFocused = true
        #endif
    }

    /// An empty name is ignored, keeping the old one.
    private func commitRename() {
        guard let id = renaming else { return }
        renaming = nil
        store.rename(id, to: newName)
    }

    private func delete(_ ids: Set<Place.ID>) {
        for id in ids { store.remove(id) }
        selection.subtract(ids)
        if let renaming, ids.contains(renaming) { self.renaming = nil }
    }
}
#endif
