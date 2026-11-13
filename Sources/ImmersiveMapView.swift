import GameController
import RealityKit
import SwiftUI

/// The map on the origin plane of the immersive space. Placement and size come
/// from the model's current presentation; the volume stays open as the control
/// panel.
struct ImmersiveMapView: View {
    static let realityKitSpaceID = "map"
    /// The immersive space to open: this one, or MetalImmersiveContent's if
    /// Settings says to draw with Metal.
    static func spaceID(for model: MapModel) -> String {
        model.drawsImmersiveWithMetal && MetalTileRenderer.shared != nil
            ? MetalImmersiveContent.spaceID : realityKitSpaceID
    }
    private static let attributionID = "attribution"

    @Environment(MapModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var headTracker = HeadTracker()

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
            let halfWidth = Float(MapModel.volumeSize.x / 2 * presentation.magnification)
            attribution.position = presentation.groundPosition + [0, 0.35, halfWidth + 0.1]
        } attachments: {
            Attachment(id: Self.attributionID) {
                VStack(spacing: 8) {
                    // The volume holds the mode picker; if it was closed,
                    // offer a way back instead of stranding the user here.
                    if !model.volumeIsOpen {
                        Button("Show Controls", systemImage: "map") {
                            openWindow(id: VolumeView.windowID)
                        }
                    }
                    // Nothing here to operate, so a pinch while looking at it
                    // goes through to the map behind and moves that.
                    AttributionView()
                        .allowsHitTesting(false)
                }
                .environment(model)
                // Terrain can rise between the viewer and the attribution;
                // draw it over the map anyway.
                .breakthroughEffect(.prominent)
            }
        }
        .mapGestures(model)
        // visionOS turns controller input into look-and-pinch events by
        // default; route it to the Game Controller framework for MapInput.
        .handlesGameControllerEvents(matching: .gamepad)
        .task {
            // Measured once, on entry: the eye the map is placed around.
            // Implausible heights (tracking glitches) keep the assumed eye.
            // MetalImmersiveRenderer measures it separately, differently
            // (notes/metal-renderer.md, "Eye height").
            if let head = await headTracker.headPosition(), (0.5...2.5).contains(head.y) {
                model.measuredEye = SIMD3<Double>(head)
            }
            headTracker.stop()
        }
        .onDisappear {
            headTracker.stop()
            model.immersiveSpaceDidClose()
        }
    }
}
