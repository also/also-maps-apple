import GameController
import SwiftUI
import UIKit

extension View {
    /// Routes game controller input in this view's window to the Game
    /// Controller framework, where MapInput polls it.
    ///
    /// By default visionOS turns controller input into pinch events aimed at
    /// whatever the user is looking at, so the framework sees the controller
    /// connect but every stick and button reads zero. A GCEventInteraction on
    /// the window opts the whole scene out of that.
    func receivesGameControllerInput() -> some View {
        background(GameControllerEventRouting())
    }
}

private struct GameControllerEventRouting: UIViewRepresentable {
    func makeUIView(context: Context) -> RoutingView { RoutingView() }
    func updateUIView(_ view: RoutingView, context: Context) {}

    final class RoutingView: UIView {
        private let interaction: GCEventInteraction = {
            let interaction = GCEventInteraction()
            interaction.handledEventTypes = .gamepad
            return interaction
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // The interaction applies to the view it's attached to and its
            // subviews; the window covers the whole scene.
            interaction.view?.removeInteraction(interaction)
            window?.addInteraction(interaction)
            #if DEBUG
            if let window {
                print("[MapVolume] game controller input routed to \(type(of: window))")
            }
            #endif
        }
    }
}
