import RealityKit
import SwiftUI

/// The map on the floor of a mixed-immersion space. Placement and size come
/// from the model's current presentation; the volume stays open as the control
/// panel.
struct ImmersiveMapView: View {
    static let spaceID = "map"
    private static let attributionID = "attribution"

    @Environment(MapVolumeModel.self) private var model

    var body: some View {
        RealityView { content, attachments in
            model.attach(content, host: .immersive)
            if let attribution = attachments.entity(for: Self.attributionID) {
                content.add(attribution)
            }
        } update: { _, attachments in
            // Keep the attribution at the map's near edge, a little above the
            // floor, as the presentation changes size.
            guard let attribution = attachments.entity(for: Self.attributionID) else { return }
            let presentation = model.presentation
            let halfWidth = Float(MapVolumeModel.volumeSize.x / 2 * presentation.magnification)
            attribution.position = presentation.groundPosition + [0, 0.35, halfWidth + 0.1]
        } attachments: {
            Attachment(id: Self.attributionID) {
                AttributionView()
                    .environment(model)
            }
        }
        .mapGestures(model)
        .onDisappear {
            model.immersiveSpaceDidClose()
        }
    }
}
