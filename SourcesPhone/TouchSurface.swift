import SwiftUI
import UIKit

/// The standard map gestures, over the whole map: drag to pan, pinch to
/// zoom, twist to turn, two fingers up or down to tilt, double tap to zoom
/// in (or hold the second tap and drag to zoom), two-finger tap to zoom out.
/// The sticks sit above it, so touches on them never reach the map.
struct TouchSurface: UIViewRepresentable {
    let map: ScreenMap

    func makeCoordinator() -> Coordinator { Coordinator(map: map) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let map: ScreenMap
        private let drag = UIPanGestureRecognizer()
        private let twoFingerPan = UIPanGestureRecognizer()
        private let pinch = UIPinchGestureRecognizer()
        private let twist = UIRotationGestureRecognizer()
        private let secondTap = UILongPressGestureRecognizer()
        private let twoFingerTap = UITapGestureRecognizer()
        /// Spacing and angle aren't reported until those gestures start, so
        /// a pinch and a tilt read the same two-finger state here.
        private var twoFingersActive = false
        private var dragging = false
        private var zoomDragStart: CGPoint?
        private var zoomDragY: CGFloat = 0
        private var zoomDragMoved = false

        /// Points of drag for a doubling, on a double tap held and dragged.
        private static let zoomDragPerDoubling: CGFloat = 120

        init(map: ScreenMap) {
            self.map = map
        }

        func install(on view: UIView) {
            drag.maximumNumberOfTouches = 1
            drag.addTarget(self, action: #selector(dragged))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.addTarget(self, action: #selector(twoFingersMoved))
            pinch.addTarget(self, action: #selector(twoFingersMoved))
            twist.addTarget(self, action: #selector(twoFingersMoved))
            // Down on the second tap, and held: a drag zooms, a release is
            // a plain double tap.
            secondTap.numberOfTapsRequired = 1
            secondTap.minimumPressDuration = 0
            secondTap.addTarget(self, action: #selector(secondTapChanged))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.addTarget(self, action: #selector(twoFingerTapped))
            for recognizer in [drag, twoFingerPan, pinch, twist, secondTap, twoFingerTap] as [UIGestureRecognizer] {
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        private func point(_ location: CGPoint) -> SIMD2<Double> {
            SIMD2(Double(location.x), Double(location.y))
        }

        @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
            // A double tap held and dragged zooms instead.
            guard zoomDragStart == nil, let view = recognizer.view else { return }
            let location = point(recognizer.location(in: view))
            switch recognizer.state {
            case .began:
                dragging = true
                map.beginDrag(at: location)
            case .changed:
                if dragging { map.drag(to: location) }
            case .ended:
                if dragging {
                    let velocity = recognizer.velocity(in: view)
                    map.endDrag(at: location, velocity: SIMD2(Double(velocity.x), Double(velocity.y)))
                }
                dragging = false
            default:
                dragging = false
            }
        }

        @objc private func twoFingersMoved(_ recognizer: UIGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed:
                guard recognizer.numberOfTouches >= 2 else { return }
                let centre = point(recognizer.location(in: view))
                if !twoFingersActive {
                    twoFingersActive = true
                    // Cancels a one-finger drag that became two.
                    dragging = false
                    resetTwoFingers(in: view)
                    map.beginTwoFingers(at: centre)
                }
                let translation = twoFingerPan.translation(in: view)
                map.twoFingers(at: centre, translation: point(translation),
                               scale: Double(pinch.scale), rotation: Double(twist.rotation))
            default:
                // Done when the last of the three has ended.
                let gestures: [UIGestureRecognizer] = [twoFingerPan, pinch, twist]
                if gestures.allSatisfy({ $0.state != .began && $0.state != .changed }) {
                    twoFingersActive = false
                    map.endTwoFingers()
                }
            }
        }

        private func resetTwoFingers(in view: UIView) {
            twoFingerPan.setTranslation(.zero, in: view)
            pinch.scale = 1
            twist.rotation = 0
        }

        @objc private func secondTapChanged(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                zoomDragStart = location
                zoomDragY = location.y
                zoomDragMoved = false
                map.beginZoomDrag(at: point(location))
            case .changed:
                guard let start = zoomDragStart else { return }
                if abs(location.y - start.y) > 8 { zoomDragMoved = true }
                guard zoomDragMoved else { return }
                // Down zooms in, as in Maps.
                let delta = Double((location.y - zoomDragY) / Self.zoomDragPerDoubling)
                zoomDragY = location.y
                map.zoomDrag(by: pow(2, delta))
            case .ended:
                map.endZoomDrag()
                if !zoomDragMoved { map.zoom(at: point(location), by: 2) }
                zoomDragStart = nil
            default:
                map.endZoomDrag()
                zoomDragStart = nil
            }
        }

        @objc private func twoFingerTapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            map.zoom(at: point(recognizer.location(in: view)), by: 0.5)
        }
    }
}
