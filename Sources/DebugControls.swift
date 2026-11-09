import SwiftUI

/// The debugging controls, as rows: in Settings' Advanced page (with notes)
/// and in the volume's debug panel (without), so the two never differ. Add
/// a control here and it shows in both.
struct DebugControls: View {
    /// Explains each control under it, for Settings.
    var showsNotes = false

    @Environment(MapModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var stateNote: String?

    var body: some View {
        @Bindable var model = model
        Toggle("Hold tiles", isOn: Binding(get: { model.tilesHeld },
                                           set: { model.setTilesHeld($0) }))
        note("Streaming keeps what's loaded and requests nothing more. You can travel about 1.5× and zoom out about 3× the held region before stopping. X on a game controller does the same.")
        Toggle("Pivot and centre markers", isOn: $model.showsDebugMarkers)
        note("Red: the point turns and zooms rotate around. Blue: the map's centre.")
        Toggle("Tile bounds", isOn: $model.showsTileBounds)
        note("Each drawn tile's box: cyan inside the LOD camera's view, orange outside. Yellow: the area of interest. Pink: the LOD camera's view; white: its view direction.")
        Button("Copy View State") {
            let json = model.captureState().json()
            UIPasteboard.general.string = json
            print("[AlsoMaps] view state: \(json)")
            stateNote = "Copied (also printed to the console)."
        }
        Button("Restore from Clipboard") {
            guard let text = UIPasteboard.general.string else {
                stateNote = "The clipboard doesn't hold a view state."
                return
            }
            let state: MapViewState
            do {
                state = try MapViewState.parse(text)
            } catch {
                stateNote = error.localizedDescription
                return
            }
            Task {
                await VolumeView.restore(state, model: model,
                                         open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
                stateNote = "Restored."
            }
        }
        if let stateNote {
            Text(stateNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func note(_ text: String) -> some View {
        if showsNotes {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The debug controls beside the volume, opened from the toolbar's wrench
/// (shown when Settings turns on Show debug controls). It stays open while
/// you move the map, so each control is one tap.
struct DebugPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug").font(.headline)
            DebugControls()
        }
        .toggleStyle(.switch)
        .buttonStyle(.bordered)
        .frame(width: 300, alignment: .leading)
        .padding(20)
        .glassBackgroundEffect()
    }
}
