import PhotosUI
import SwiftUI

/// Adds photos with the system photo picker, which runs out of process and
/// needs no library permission. `.current` asks for the original encoding,
/// with its metadata; `photoLibrary: .shared()` gives each item its asset
/// identifier, for the PhotoKit fallback when the data has no location.
struct AddPhotosButton: View {
    let session: PhotoSession
    @State private var items: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $items, maxSelectionCount: 30, matching: .images,
                     preferredItemEncoding: .current, photoLibrary: .shared()) {
            Label("Add Photos", systemImage: "photo.badge.plus")
        }
        .disabled(session.isImporting)
        .help("Place your photos where they were taken")
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            items = []
            Task { await session.add(picked) }
        }
    }
}

/// The photos placed this session: go to one, search the library near
/// here, or clear them.
struct PhotosMenu: View {
    let session: PhotoSession
    /// Runs before standing in a photo: on visionOS, opens Immersive.
    var prepare: (() async -> Void)?

    var body: some View {
        Menu("Photos", systemImage: "photo.on.rectangle.angled") {
            if session.photos.isEmpty {
                Text(session.isImporting ? "Reading photos…" : "No photos yet")
            }
            ForEach(session.photos) { photo in
                Button {
                    Task {
                        await prepare?()
                        session.stand(in: photo.id)
                    }
                } label: {
                    Label(photo.name, systemImage: photo.id == session.activeID ? "eye" : "mappin.and.ellipse")
                }
            }
            if let message = session.message {
                Text(message)
            }
            Divider()
            Button("Photos Near Here", systemImage: "location.magnifyingglass") {
                Task { await session.addNearby() }
            }
            .disabled(session.isImporting)
            if !session.photos.isEmpty {
                Button("Remove All Photos", systemImage: "trash", role: .destructive) {
                    session.removeAll()
                }
            }
        }
        .help("Your photos, placed where they were taken")
    }
}

/// While standing in a photo: the photo/world fade, nudges to line it up,
/// and a way out. In the immersive space it hangs under the frame; on the
/// Mac it sits over the view.
struct PhotoViewerControls: View {
    @Bindable var session: PhotoSession

    /// Half a degree a press: compass headings are usually a few degrees
    /// out, so a few presses line most photos up.
    private static let step = 0.5 * Double.pi / 180

    var body: some View {
        if let photo = session.active {
            VStack(spacing: 8) {
                Text(photo.name).font(.headline)
                HStack {
                    Image(systemName: "globe.americas")
                        .accessibilityLabel("World")
                    Slider(value: $session.frameOpacity, in: 0...1)
                        .frame(width: 260)
                    Image(systemName: "photo")
                        .accessibilityLabel("Photo")
                }
                HStack(spacing: 10) {
                    nudge("Aim Left", "arrow.left") { session.nudge(heading: -Self.step) }
                    nudge("Aim Right", "arrow.right") { session.nudge(heading: Self.step) }
                    nudge("Aim Up", "arrow.up") { session.nudge(pitch: Self.step) }
                    nudge("Aim Down", "arrow.down") { session.nudge(pitch: -Self.step) }
                    Button("Reset", systemImage: "arrow.uturn.backward") { session.resetAdjustment() }
                        .disabled(photo.adjustment == .none)
                    Button("Leave Photo", systemImage: "xmark") { session.leave() }
                }
                .labelStyle(.iconOnly)
                Text(Self.status(photo))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .padding(12)
            #if os(visionOS)
            .glassBackgroundEffect()
            #else
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            #endif
        }
    }

    private func nudge(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .help(title)
    }

    /// The adjustment, and what's guessed about this photo's pose.
    private static func status(_ photo: PlacedPhoto) -> String {
        let degrees = 180 / Double.pi
        var parts = [String(format: "Heading %+.1f°, pitch %+.1f°",
                            photo.adjustment.heading * degrees, photo.adjustment.pitch * degrees)]
        switch PhotoGeometry.heading(photo.metadata) {
        case nil: parts.append("no compass direction (facing north)")
        case let heading? where heading.isMagnetic: parts.append("magnetic heading, uncorrected")
        default: break
        }
        if photo.fieldOfView.source == .assumed { parts.append("lens unknown (26 mm assumed)") }
        if photo.locationSource == .photoLibrary { parts.append("location from your library") }
        switch PhotoPose.eyeHeight(ground: photo.ground, recordedAltitude: photo.metadata.altitude)?.source {
        case .recorded? where photo.ground == nil: parts.append("waiting for the ground")
        case .recorded?: parts.append("eye at the recorded altitude")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}
