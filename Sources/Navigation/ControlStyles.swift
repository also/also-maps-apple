import Foundation
import simd

/// Rates and inputs shared by the control styles: per-second rates, each
/// −1…1 (move is a vector of length ≤ 1).
struct ControlInput: Equatable {
    var move = SIMD2<Double>.zero
    var turn = 0.0
    var climb = 0.0
    var dolly = 0.0
    /// Look up (+) / down (−). Only hosts whose view follows the camera's
    /// pitch (flat screens) send it.
    var pitch = 0.0
    var fast = false

    var boost: Double { fast ? 3 : 1 }
}

/// Model flight, today's controls on the camera core: forward/right along
/// the movement heading (linked to the view heading), climb straight up,
/// turn in place, dolly along the view. Rates are starting values for
/// tuning.
struct ModelFlightStyle {
    /// Fraction of height above ground travelled per second.
    var moveRate = 0.75
    /// Radians per second.
    var turnRate = Double.pi / 3
    /// e-folds of height above ground per second.
    var climbRate = 1.0
    /// e-folds of range per second.
    var dollyRate = 1.0
    /// Radians per second.
    var pitchRate = Double.pi / 4
    /// Surface the dolly target is found on along the view, metres above
    /// the ellipsoid.
    var dollySurfaceHeight = 0.0
    /// In a room host, where pitch doesn't show: the camera moved to a
    /// height with its view centre held in place. Zoom then changes the
    /// height above the dolly surface, and the view centre stays put.
    /// Without it, zoom dollies along the view.
    var holdingViewCentre: ((CameraPose, _ height: Double) -> CameraPose)?
    /// A height above the ellipsoid zoom works below, if any: zooming out
    /// stops 1% short of it, so there's room to zoom back in, and above it
    /// (climbed to) zoom does nothing either way. Climbing isn't limited.
    ///
    /// Nothing about the world needs this limit. It keeps zoom out of the
    /// room hosts' tilt range, where the immersive space's view centre isn't
    /// settled yet (#67).
    var zoomCeiling: Double?
    /// How far short of `zoomCeiling` zooming out stops, as a fraction.
    static let zoomCeilingMargin = 0.01

    /// Takes over from another style: the view is unchanged, and movement
    /// heading follows the view from here on.
    func activate(_ state: NavigationState) -> NavigationState {
        var state = state
        state.headingLink = .linked
        state.movementHeading = state.camera.heading
        return state
    }

    func step(_ state: NavigationState, input: ControlInput, deltaTime: Double,
              context: NavigationContext) -> NavigationState {
        var state = state
        let boost = input.boost
        if input.turn != 0 {
            state = NavigationOperations.turn(state, by: input.turn * turnRate * boost * deltaTime)
        }
        if input.pitch != 0 {
            state = NavigationOperations.pitch(state, by: input.pitch * pitchRate * boost * deltaTime)
        }
        if input.climb != 0 {
            let altitude = context.altitude(of: state.camera)
            let target = altitude * exp(input.climb * climbRate * boost * deltaTime)
            state = NavigationOperations.climb(state, by: target - altitude, context: context)
        }
        let belowCeiling = zoomCeiling.map { state.camera.height < $0 } ?? true
        if input.dolly != 0, belowCeiling {
            var context = context
            if let zoomCeiling {
                let stop = zoomCeiling * (1 - Self.zoomCeilingMargin)
                context.maximumAltitude = min(context.maximumAltitude,
                                              max(stop, state.camera.height) - context.cameraGround)
            }
            let camera = state.camera
            let ray = Ray(origin: camera.position, direction: camera.basis.forward)
            let fraction = 1 - exp(-input.dolly * dollyRate * boost * deltaTime)
            if let holdingViewCentre {
                let above = camera.height - dollySurfaceHeight
                let height = context.clampHeight(dollySurfaceHeight + above * (1 - min(fraction, 0.95)))
                // At a height limit, stay put rather than nudge the view.
                if height != camera.height {
                    let moved = holdingViewCentre(camera, height)
                    let turn = NavigationOperations.wrapped(moved.heading - camera.heading)
                    state.camera = moved
                    state.movementHeading = NavigationOperations.wrapped(state.movementHeading + turn)
                }
            } else if case let .hit(point, _) = Geodesy.intersect(ray: ray, surfaceHeight: dollySurfaceHeight) {
                // Declines on a miss: there's nothing to approach.
                state = NavigationOperations.dolly(state, toward: point, fraction: fraction, context: context)
            }
        }
        if input.move != .zero {
            let metres = context.altitude(of: state.camera) * moveRate * boost * deltaTime
            state = NavigationOperations.move(state, forward: input.move.y * metres, right: input.move.x * metres)
        }
        return state
    }
}

/// Orbit, pan and zoom about a pivot, as on a Mac. Owns its pivot; movement
/// heading is left alone (independent), and pans follow the view heading.
struct OrbitStyle {
    /// ECEF.
    var pivot: SIMD3<Double>
    /// Radians per second.
    var orbitRate = Double.pi / 3
    /// e-folds of distance to the pivot per second.
    var zoomRate = 1.0

    /// Takes over from another style without moving the view: the pivot is
    /// where the view ray meets the surface at `surfaceHeight`, or, on a
    /// miss, the declared fallback, the ground beneath the camera.
    static func activate(_ state: NavigationState, surfaceHeight: Double) -> (NavigationState, OrbitStyle) {
        var state = state
        state.headingLink = .independent
        let camera = state.camera
        let ray = Ray(origin: camera.position, direction: camera.basis.forward)
        let pivot: SIMD3<Double>
        if case let .hit(point, _) = Geodesy.intersect(ray: ray, surfaceHeight: surfaceHeight) {
            pivot = point
        } else {
            pivot = Geodesy.ecef(camera.coordinate, height: min(surfaceHeight, camera.height))
        }
        return (state, OrbitStyle(pivot: pivot))
    }

    /// `input.turn` orbits, `input.dolly` zooms toward the pivot and
    /// `input.move` pans camera and pivot together.
    mutating func step(_ state: NavigationState, input: ControlInput, deltaTime: Double,
                       context: NavigationContext) -> NavigationState {
        var state = state
        let boost = input.boost
        if input.turn != 0 {
            state = NavigationOperations.orbit(state, about: pivot,
                                               by: input.turn * orbitRate * boost * deltaTime, context: context)
        }
        if input.dolly != 0 {
            let fraction = 1 - exp(-input.dolly * zoomRate * boost * deltaTime)
            state = NavigationOperations.dolly(state, toward: pivot, fraction: fraction, context: context)
        }
        if input.move != .zero {
            let metres = simd_distance(state.camera.position, pivot) * 0.75 * boost * deltaTime
            let (pivotCoordinate, pivotHeight) = Geodesy.geodetic(pivot)
            // Pan along the view heading, whatever the movement heading is.
            var panning = state
            panning.movementHeading = state.camera.heading
            let moved = NavigationOperations.move(panning, forward: input.move.y * metres,
                                                  right: input.move.x * metres)
            let bearing = state.camera.heading + atan2(input.move.x, input.move.y)
            let pivotEnd = GeoMath.destination(from: pivotCoordinate, bearing: bearing, distance: metres * simd_length(input.move))
            pivot = Geodesy.ecef(pivotEnd, height: pivotHeight)
            let movementChange = moved.movementHeading - panning.movementHeading
            state.camera = moved.camera
            state.movementHeading = NavigationOperations.wrapped(state.movementHeading + movementChange)
        }
        return state
    }
}
