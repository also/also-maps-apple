import RealityKit
import SwiftUI

struct MapVolumeView: View {
    @State private var model = MapVolumeModel()

    var body: some View {
        RealityView { content in
            content.add(model.root)
            model.start(subscribingIn: content)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .targetedToEntity(model.gestureTarget)
                .onChanged { value in
                    let start = value.convert(value.startLocation3D, from: .local, to: .scene)
                    let now = value.convert(value.location3D, from: .local, to: .scene)
                    model.drag(translation: now - start)
                }
                .onEnded { _ in model.endDrag() }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .targetedToEntity(model.gestureTarget)
                .onChanged { value in model.magnify(by: value.magnification) }
                .onEnded { _ in model.endMagnify() }
        )
        .ornament(attachmentAnchor: .scene(.bottomFront)) {
            attribution
        }
    }

    /// Google's terms require the attribution for the tiles on screen to be
    /// visible. TODO: use the official Google logo asset instead of text.
    private var attribution: some View {
        VStack(spacing: 4) {
            if let message = model.statusMessage {
                Text(message).font(.callout)
            } else if model.loadProgress < 100 {
                ProgressView(value: Double(model.loadProgress), total: 100)
                    .frame(width: 200)
            }
            HStack(spacing: 8) {
                Text("Google").font(.headline)
                Text(model.credits.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
    }
}
