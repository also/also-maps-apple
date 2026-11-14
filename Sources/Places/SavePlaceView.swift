#if !os(tvOS)
import SwiftUI

/// A view to save to My Map: the place, and the camera it was seen from,
/// which the name suggestions describe.
struct PlaceToSave: Identifiable {
    var place: Place
    var camera: CameraPose
    var id: Place.ID { place.id }
}

/// Saving a view to My Map: its name, filled in with the first of
/// PlaceNamer's suggestions and free to edit, with the other suggestions to
/// pick from. The on-device model's suggestions join the list when they
/// arrive.
struct SavePlaceView: View {
    var saving: PlaceToSave
    var done: () -> Void
    @State private var name = ""
    @State private var suggestions: [String] = []
    @State private var askingModel = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save to My Map")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
            let others = suggestions.filter { $0 != trimmedName }
            if !others.isEmpty || askingModel {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Suggestions")
                        if askingModel { ProgressView().controlSize(.small) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(others, id: \.self) { suggestion in
                        Button(suggestion) { name = suggestion }
                            .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding()
        .frame(width: 340)
        .task {
            suggestions = await PlaceNamer.suggestions(for: saving.place, camera: saving.camera)
            // Unless the user has started typing.
            if name.isEmpty, let first = suggestions.first { name = first }
            nameFocused = true

            askingModel = true
            let more = await PlaceNamer.modelSuggestions(
                for: saving.place, camera: saving.camera,
                existingNames: PlaceStore.shared.myMap.map(\.name))
            askingModel = false
            let known = Set(suggestions.map { $0.lowercased() })
            suggestions += more.filter { !known.contains($0.lowercased()) }
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        var saved = saving.place
        saved.name = trimmedName
        PlaceStore.shared.add(saved)
        done()
    }
}
#endif
