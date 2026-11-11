import SwiftUI

/// The camera diagram as a debug window: side views of where the current
/// view puts the world, live, from the same inputs the placement uses.
/// Opened from the debug controls.
struct CameraDiagramWindow: View {
    static let windowID = "camera-diagram"

    @Environment(MapModel.self) private var model

    var body: some View {
        let diagram = CameraDiagram(model.diagramInputs)
        let host = model.presentation.host == .volume ? "The volume" : "The immersive space"
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panel("World, along the heading") {
                    CameraDiagramWorldView(diagram: diagram).frame(height: 300)
                }
                panel("\(host), from the side") {
                    CameraDiagramRoomView(diagram: diagram).frame(height: 260)
                }
                CameraDiagramLegend(diagram: diagram)
                CameraDiagramReadouts(diagram: diagram).font(.callout)
            }
            .padding(24)
        }
    }

    private func panel(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
