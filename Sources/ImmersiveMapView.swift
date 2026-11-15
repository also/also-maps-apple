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
    private static let locationLabelID = "location-label"
    /// The location label's place relative to the reference head pose:
    /// this far away, straight ahead and this far above level, tipped to
    /// face it. High enough to clear the map ahead, low enough to stay in
    /// view while you look at the horizon.
    private static let locationLabelDistance: Float = 1.5
    private static let locationLabelElevation: Float = 12 * .pi / 180

    @Environment(MapModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var headTracker = HeadTracker()
    @State private var locationLabel = LocationLabel()
    @AppStorage(ViewPreferences.showsLocationLabelKey) private var showsLocationLabel = false

    var body: some View {
        RealityView { content, attachments in
            model.attach(content, host: .immersive)
            if let attribution = attachments.entity(for: Self.attributionID) {
                content.add(attribution)
            }
            if let label = attachments.entity(for: Self.locationLabelID) {
                content.add(label)
            }
        } update: { _, attachments in
            if let label = attachments.entity(for: Self.locationLabelID) {
                label.isEnabled = showsLocationLabel
                if showsLocationLabel {
                    let head = model.referenceHead
                    let yaw = simd_quatf(angle: Float(head.yaw), axis: [0, 1, 0])
                    let e = Self.locationLabelElevation
                    label.position = SIMD3<Float>(head.position)
                        + yaw.act([0, sin(e), -cos(e)]) * Self.locationLabelDistance
                    // Tipped back by the elevation, so it faces the head.
                    label.orientation = yaw * simd_quatf(angle: e, axis: [1, 0, 0])
                }
            }
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
            }
            Attachment(id: Self.locationLabelID) {
                if showsLocationLabel {
                    LocationLabelView(label: locationLabel)
                }
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
        .task(id: showsLocationLabel) {
            guard showsLocationLabel else { return }
            await locationLabel.run { model.navigation.camera }
        }
        .onDisappear {
            headTracker.stop()
            model.immersiveSpaceDidClose()
        }
    }
}
