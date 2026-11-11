import Foundation
import simd

/// What navigation operations need to know beyond the state itself.
struct NavigationContext: Equatable {
    /// Estimated ground under the camera, metres above the ellipsoid.
    var cameraGround = 0.0
    /// Lowest height above that ground the camera may go.
    var minimumAltitude = 1.5
    /// Highest height above that ground the camera may go.
    var maximumAltitude = 20_000_000.0

    func clampHeight(_ height: Double) -> Double {
        min(max(height, cameraGround + minimumAltitude), cameraGround + maximumAltitude)
    }

    /// Height above the estimated ground, at least `floor` metres, for speeds.
    func altitude(of camera: CameraPose, floor: Double = 10) -> Double {
        max(camera.height - cameraGround, floor)
    }
}

/// Pure operations on navigation state. "View heading" is camera.heading;
/// under `.linked`, every change to it is applied to the movement heading
/// too.
enum NavigationOperations {
    /// Changes height only: latitude, longitude and both headings stay.
    static func climb(_ state: NavigationState, by delta: Double, context: NavigationContext) -> NavigationState {
        var state = state
        state.camera.height = context.clampHeight(state.camera.height + delta)
        return state
    }

    /// Turns the view in place.
    static func turn(_ state: NavigationState, by delta: Double) -> NavigationState {
        var state = state
        state.camera.heading = wrapped(state.camera.heading + delta)
        if state.headingLink == .linked { state.movementHeading = state.camera.heading }
        return state
    }

    static func faceNorth(_ state: NavigationState) -> NavigationState {
        var state = state
        state.camera.heading = 0
        if state.headingLink == .linked { state.movementHeading = 0 }
        return state
    }

    /// Changes view pitch within `range` (the style's limits).
    static func pitch(_ state: NavigationState, by delta: Double,
                      range: ClosedRange<Double> = (-Double.pi / 2)...(Double.pi * 4 / 9)) -> NavigationState {
        var state = state
        state.camera.pitch = min(max(state.camera.pitch + delta, range.lowerBound), range.upperBound)
        return state
    }

    /// Travels along the globe, `forward` metres along the movement heading
    /// and `right` metres across it, at constant height. Both headings are
    /// carried along the great circle, so flying over a pole continues.
    static func move(_ state: NavigationState, forward: Double, right: Double) -> NavigationState {
        let distance = (forward * forward + right * right).squareRoot()
        guard distance > 0 else { return state }
        let start = state.camera.coordinate
        let end = GeoMath.destination(from: start,
                                      bearing: state.movementHeading + atan2(right, forward),
                                      distance: distance)
        let change = GeoMath.bearingChange(from: start, to: end)
        var state = state
        state.camera.latitude = end.latitude
        state.camera.longitude = end.longitude
        state.camera.heading = wrapped(state.camera.heading + change)
        state.movementHeading = wrapped(state.movementHeading + change)
        return state
    }

    /// Moves the camera toward `target` (ECEF) by `fraction` of the distance
    /// (negative backs away), keeping its viewing direction.
    static func dolly(_ state: NavigationState, toward target: SIMD3<Double>, fraction: Double,
                      context: NavigationContext) -> NavigationState {
        let position = state.camera.position
        let moved = position + (target - position) * min(fraction, 0.95)
        return place(state, at: moved, forward: state.camera.basis.forward, context: context)
    }

    /// Swings the camera around the vertical through `pivot` (ECEF) by
    /// `delta` radians clockwise seen from above, turning the view with it so
    /// it keeps facing the same way relative to the pivot.
    static func orbit(_ state: NavigationState, about pivot: SIMD3<Double>, by delta: Double,
                      context: NavigationContext) -> NavigationState {
        let (pivotCoordinate, _) = Geodesy.geodetic(pivot)
        let axis = Geodesy.enu(latitude: pivotCoordinate.latitude, longitude: pivotCoordinate.longitude).up
        // Clockwise from above is negative about up.
        let rotation = simd_quatd(angle: -delta, axis: axis)
        let position = pivot + rotation.act(state.camera.position - pivot)
        var orbited = place(state, at: position, forward: rotation.act(state.camera.basis.forward), context: context)
        if state.headingLink == .linked { orbited.movementHeading = orbited.camera.heading }
        return orbited
    }

    /// Swings the camera up or down an arc around `pivot` (ECEF), turning
    /// the view with it, so what's at the pivot stays where it is on screen
    /// and the map seems to tip. Positive `delta` (radians) levels the view,
    /// bringing the camera down. Pitch stays within `range`, or where it
    /// already is if that's outside it.
    static func tilt(_ state: NavigationState, about pivot: SIMD3<Double>, by delta: Double,
                     range: ClosedRange<Double>, context: NavigationContext) -> NavigationState {
        let pitch = state.camera.pitch
        let lowest = min(range.lowerBound, pitch), highest = max(range.upperBound, pitch)
        let angle = min(max(pitch + delta, lowest), highest) - pitch
        guard angle != 0 else { return state }
        let basis = state.camera.basis
        let rotation = simd_quatd(angle: angle, axis: basis.right)
        let position = pivot + rotation.act(state.camera.position - pivot)
        return place(state, at: position, forward: rotation.act(basis.forward), context: context)
    }

    /// The state with the camera at `position` looking along `forward`
    /// (ECEF), height clamped. Movement heading is carried with the move.
    private static func place(_ state: NavigationState, at position: SIMD3<Double>, forward: SIMD3<Double>,
                              context: NavigationContext) -> NavigationState {
        var camera = CameraPose(position: position, forward: forward, fallbackHeading: state.camera.heading)
        camera.height = context.clampHeight(camera.height)
        var state = state
        let change = GeoMath.bearingChange(from: state.camera.coordinate, to: camera.coordinate)
        state.movementHeading = wrapped(state.movementHeading + change)
        state.camera = camera
        return state
    }

    static func wrapped(_ angle: Double) -> Double {
        remainder(angle, 2 * .pi)
    }
}
