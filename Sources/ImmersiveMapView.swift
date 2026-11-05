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
    private static let creditsInViewID = "credits-in-view"
    /// Where the credits sit when they stay in view, in the head's frame:
    /// 1 m ahead and about 11° below straight ahead, tilted to face the eye.
    /// Low in the view but inside the frame of a screen recording.
    private static let creditsInViewPosition: SIMD3<Float> = [0, -0.2, -1]

    @Environment(MapModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// Recording mode keeps the credits in view.
    @AppStorage(ViewPreferences.recordingModeKey) private var recordingMode = false
    @State private var headTracker = HeadTracker()

    var body: some View {
        RealityView { content, attachments in
            model.attach(content, host: .immersive)
            if let attribution = attachments.entity(for: Self.attributionID) {
                content.add(attribution)
            }
            // Fixed in your view, wherever you look. The head anchor needs no
            // ARKit session and follows the head at display rate.
            if let credits = attachments.entity(for: Self.creditsInViewID) {
                let head = AnchorEntity(.head, trackingMode: .continuous)
                let offset = Self.creditsInViewPosition
                credits.position = offset
                credits.orientation = simd_quatf(angle: -atan2(-offset.y, -offset.z), axis: [1, 0, 0])
                head.addChild(credits)
                content.add(head)
            }
        } update: { _, attachments in
            attachments.entity(for: Self.creditsInViewID)?.isEnabled = recordingMode
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
                    // With the credits in view, the rest (loading, stats)
                    // stays here.
                    AttributionView(showsCredits: !recordingMode)
                }
                .environment(model)
            }
            Attachment(id: Self.creditsInViewID) {
                // With the promotional line, which AttributionCredits adds in
                // recording mode.
                AttributionCredits()
                    .attributionPanel()
                    // Nothing to press, so pinches go to the map behind it.
                    .allowsHitTesting(false)
                    .environment(model)
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
