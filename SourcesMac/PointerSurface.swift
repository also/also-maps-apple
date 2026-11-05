import AppKit
import SwiftUI

/// The standard map controls for a mouse or trackpad, over the whole map:
/// drag to pan, right-drag (or Option- or Control-drag) to turn and tilt,
/// double-click to zoom in and Option-double-click to zoom out. Pinch zooms,
/// twisting turns, and scrolling does what `ScrollGesture` says. The map's
/// controls sit above it, so clicks on them never reach the map.
struct PointerSurface: NSViewRepresentable {
    let map: ScreenMap

    func makeNSView(context: Context) -> SurfaceView { SurfaceView(map: map) }

    func updateNSView(_ nsView: SurfaceView, context: Context) {}

    final class SurfaceView: NSView {
        private let map: ScreenMap
        private var mode = DragMode.none
        /// Where the pointer has been lately, to tell a flick when it lets go.
        private var recentDrag: [(point: SIMD2<Double>, time: TimeInterval)] = []
        /// Pinching and twisting are separate gestures that run together.
        private var pinching = false
        private var twisting = false
        private var scale = 1.0
        private var clickStart: SIMD2<Double>?
        private var rotation = 0.0

        private enum DragMode { case none, pan, orbit(from: SIMD2<Double>) }

        /// How far back a release looks for a flick, seconds.
        private static let flickWindow = 0.08

        init(map: ScreenMap) {
            self.map = map
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        // Same coordinates as the touch surface: points, y down.
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        private func point(_ event: NSEvent) -> SIMD2<Double> {
            let location = convert(event.locationInWindow, from: nil)
            return SIMD2(Double(location.x), Double(location.y))
        }

        // MARK: Clicks and drags

        override func mouseDown(with event: NSEvent) {
            let location = point(event)
            if event.clickCount == 2 {
                map.zoom(at: location, by: event.modifierFlags.contains(.option) ? 0.5 : 2)
                mode = .none
            } else if !event.modifierFlags.isDisjoint(with: [.option, .control]) {
                mode = .orbit(from: location)
            } else {
                mode = .pan
                clickStart = location
                recentDrag = [(location, event.timestamp)]
                map.beginDrag(at: location)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            dragged(event)
        }

        override func mouseUp(with event: NSEvent) {
            if case .pan = mode {
                dragged(event)
                // A press and release in the same place is a click.
                if let start = clickStart, simd_distance(start, point(event)) < 4 { map.tap(at: start) }
                map.endDrag(at: point(event), velocity: flickVelocity(at: event.timestamp))
            }
            mode = .none
        }

        override func rightMouseDown(with event: NSEvent) {
            mode = .orbit(from: point(event))
        }

        override func rightMouseDragged(with event: NSEvent) {
            dragged(event)
        }

        override func rightMouseUp(with event: NSEvent) {
            mode = .none
        }

        private func dragged(_ event: NSEvent) {
            let location = point(event)
            switch mode {
            case .none:
                break
            case .pan:
                recentDrag.append((location, event.timestamp))
                recentDrag.removeAll { event.timestamp - $0.time > Self.flickWindow }
                map.drag(to: location)
            case let .orbit(from):
                map.orbit(by: location - from)
                mode = .orbit(from: location)
            }
        }

        /// Points per second over the last moment of the drag; nothing if
        /// the pointer stopped before letting go.
        private func flickVelocity(at time: TimeInterval) -> SIMD2<Double> {
            guard let first = recentDrag.first(where: { time - $0.time <= Self.flickWindow }),
                  let last = recentDrag.last, last.time > first.time
            else { return .zero }
            return (last.point - first.point) / (last.time - first.time)
        }

        // MARK: Scrolling

        override func scrollWheel(with event: NSEvent) {
            let gesture = ScrollGesture(delta: SIMD2(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY)),
                                        isPrecise: event.hasPreciseScrollingDeltas,
                                        isInverted: event.isDirectionInvertedFromDevice,
                                        zooms: event.modifierFlags.contains(.option),
                                        tilts: event.modifierFlags.contains(.shift))
            switch gesture.action {
            case .none:
                break
            case let .pan(delta):
                map.scroll(by: delta)
            case let .zoom(doublings):
                map.zoom(at: point(event), by: pow(2, doublings))
            case let .tilt(points):
                map.orbit(by: SIMD2(0, points))
            }
        }

        // MARK: Pinch and twist

        override func magnify(with event: NSEvent) {
            if event.phase == .began { beginTwoFingers(event) }
            pinching = isRunning(event.phase)
            scale *= 1 + Double(event.magnification)
            updateTwoFingers(event)
        }

        override func rotate(with event: NSEvent) {
            if event.phase == .began { beginTwoFingers(event) }
            twisting = isRunning(event.phase)
            // Degrees counterclockwise; the map takes radians clockwise.
            rotation -= Double(event.rotation) * .pi / 180
            updateTwoFingers(event)
        }

        private func isRunning(_ phase: NSEvent.Phase) -> Bool {
            !phase.isDisjoint(with: [.began, .changed, .stationary])
        }

        /// A pinch and a twist that overlap are one gesture to the map.
        private func beginTwoFingers(_ event: NSEvent) {
            guard !pinching, !twisting else { return }
            scale = 1
            rotation = 0
            map.beginTwoFingers(at: point(event))
        }

        private func updateTwoFingers(_ event: NSEvent) {
            if pinching || twisting {
                map.twoFingers(at: point(event), translation: .zero, scale: scale, rotation: rotation)
            } else {
                map.endTwoFingers()
            }
        }

        /// A double tap with two fingers on a trackpad.
        override func smartMagnify(with event: NSEvent) {
            map.zoom(at: point(event), by: 2)
        }
    }
}
