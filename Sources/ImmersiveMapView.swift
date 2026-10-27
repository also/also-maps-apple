import GameController
import RealityKit
import SwiftUI

/// The map on the origin plane of the immersive space. Placement and size come
/// from the model's current presentation; the volume stays open as the control
/// panel.
struct ImmersiveMapView: View {
    static let spaceID = "map"
    private static let attributionID = "attribution"

    @Environment(MapVolumeModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RealityView { content, attachments in
            model.attach(content, host: .immersive)
            if let attribution = attachments.entity(for: Self.attributionID) {
                content.add(attribution)
            }
        } update: { _, attachments in
            // Keep the attribution at the map's near edge, a little above the
            // origin plane, as the presentation changes size.
            guard let attribution = attachments.entity(for: Self.attributionID) else { return }
            let presentation = model.presentation
            let halfWidth = Float(MapVolumeModel.volumeSize.x / 2 * presentation.magnification)
            attribution.position = presentation.groundPosition + [0, 0.35, halfWidth + 0.1]
        } attachments: {
            Attachment(id: Self.attributionID) {
                VStack(spacing: 8) {
                    // The volume holds the mode picker; if it was closed,
                    // offer a way back instead of stranding the user here.
                    if !model.volumeIsOpen {
                        Button("Show Controls", systemImage: "map") {
                            openWindow(id: MapVolumeView.windowID)
                        }
                    }
                    AttributionView()
                }
                .environment(model)
            }
        }
        .mapGestures(model)
        // visionOS turns controller input into look-and-pinch events by
        // default; route it to the Game Controller framework for MapInput.
        .handlesGameControllerEvents(matching: .gamepad)
        .onDisappear {
            model.immersiveSpaceDidClose()
        }
    }
}
