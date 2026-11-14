#if !os(tvOS)
import SwiftUI

/// My Map's places, to rename, delete and reorder the way each platform
/// edits a list. Its own window on visionOS and the Mac, a sheet on iPhone.
///
/// - visionOS: the My Map window, usable on its own (in an immersive space
///   with the volume's controls closed, say). Tapping a place goes there;
///   + saves the current view; the … menu has Edit and Share My Map.
/// - Mac: a selectable list. Return or double-click renames the selected
///   place in its row; Delete (or Edit > Delete) and the − button delete
///   the selection; rows drag to reorder.
/// - iPhone: tapping a place renames it.
/// - iPhone, visionOS: Edit puts the list in edit mode, with the system's
///   delete and reorder controls; rows also swipe to delete or rename.
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
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    #if os(visionOS)
    @Environment(MapModel.self) private var model
    @State private var editMode: EditMode = .inactive
    /// The view being saved with +, while its name is chosen.
    @State private var savingPlace: PlaceToSave?
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
                    #if os(visionOS)
                    ToolbarItemGroup(placement: .primaryAction) { windowActions }
                    #else
                    ToolbarItem(placement: .primaryAction) { EditButton() }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    #endif
                }
                #if os(visionOS)
                .environment(\.editMode, $editMode)
                .sheet(item: $savingPlace) { saving in
                    SavePlaceView(saving: saving) { savingPlace = nil }
                }
                #endif
                .alert("Rename Place", isPresented: Binding(get: { renaming != nil },
                                                           set: { if !$0 { renaming = nil } })) {
                    TextField("Name", text: $newName)
                    Button("Rename") { commitRename() }
                    Button("Cancel", role: .cancel) {}
                }
        }
        #endif
    }

    #if os(visionOS)
    /// + to save the current view, and … for Edit and Share My Map; Done
    /// while editing.
    @ViewBuilder private var windowActions: some View {
        if editMode.isEditing {
            Button("Done") { editMode = .inactive }
        } else {
            Button("Save to My Map", systemImage: "plus") {
                savingPlace = PlaceToSave(place: model.currentPlace(id: UUID().uuidString, name: ""),
                                          viewCenter: model.viewCenter)
            }
            .help("Save this view to My Map")
            Menu("More", systemImage: "ellipsis") {
                Button("Edit", systemImage: "pencil") { editMode = .active }
                if !store.myMap.isEmpty {
                    ShareLink(item: store.myMapFile) {
                        Label("Share My Map", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .disabled(store.myMap.isEmpty)
        }
    }
    #endif

    private var list: some View {
        // A selection would turn iPhone and visionOS edit mode into
        // multiple selection, without the delete controls.
        Group {
            #if os(macOS)
            List(selection: $selection) { rows }
            #else
            List { rows }
            #endif
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

    private var rows: some View {
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
        #elseif os(visionOS)
        Button(place.name) { model.go(to: place) }
            .tint(.primary)
        #else
        Button {
            beginRename(place)
        } label: {
            HStack {
                Text(place.name)
                Spacer()
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        // Names in the text color, like other list rows.
        .tint(.primary)
        .accessibilityHint("Renames the place")
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
