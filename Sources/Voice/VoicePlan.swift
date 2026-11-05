import Foundation
import FoundationModels

/// What the on-device model turns a spoken request into: actions with the
/// numbers and units as said. Converting units and filling in defaults is
/// done here in code, which the small model is less reliable at.
@Generable(description: "The map commands in a spoken request, in the order spoken")
struct VoicePlan: Equatable {
    @Guide(description: "One entry per command; empty if the request isn't a map command")
    var commands: [SpokenCommand]
}

@Generable
struct SpokenCommand: Equatable {
    var action: SpokenAction
    @Guide(description: "The number spoken with the command, if any, as a positive number")
    var amount: Double?
    @Guide(description: "The unit spoken with the amount, if any")
    var unit: SpokenUnit?
    @Guide(description: "For goTo only: the place name exactly as spoken, including any city or country")
    var place: String?
    @Guide(description: "For face only: the compass direction spoken")
    var direction: CompassDirection?
}

@Generable
enum SpokenAction: String, Equatable {
    /// Go to a named place.
    case goTo
    /// Up / ascend / climb / higher.
    case climb
    /// Down / descend / lower.
    case descend
    /// "Go to 500 feet", "altitude 2 km": an absolute height.
    case setAltitude
    case turnLeft
    case turnRight
    /// Face a compass direction, or a heading in degrees.
    case face
    case moveForward
    case moveBack
    case moveLeft
    case moveRight
    case lookUp
    case lookDown
    case zoomIn
    case zoomOut
}

@Generable
enum SpokenUnit: String, Equatable {
    case feet, meters, kilometers, miles, degrees, times
}

@Generable
enum CompassDirection: String, Equatable {
    case north, northeast, east, southeast, south, southwest, west, northwest

    var degrees: Double {
        switch self {
        case .north: 0
        case .northeast: 45
        case .east: 90
        case .southeast: 135
        case .south: 180
        case .southwest: 225
        case .west: 270
        case .northwest: 315
        }
    }
}

extension SpokenCommand {
    /// The command this means for a camera `altitude` metres above the
    /// ground; nil when it can't be carried out (goTo without a place).
    func mapCommand(altitude: Double) -> MapCommand? {
        let amount = amount.map(abs)
        /// A distance in metres, or `fallback` if none was said.
        func metres(_ fallback: Double) -> Double {
            guard let amount else { return fallback }
            switch unit {
            case .feet: return amount * 0.3048
            case .kilometers: return amount * 1_000
            case .miles: return amount * 1_609.344
            default: return amount
            }
        }
        func degrees(_ fallback: Double) -> Double { amount ?? fallback }
        /// "Zoom in 2 times" or "zoom in" (twice as close).
        var factor: Double { max(amount ?? 2, 1.01) }

        switch action {
        case .goTo:
            guard let place, !place.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return .goTo(destination: .named(name: place))
        case .climb: return .climb(meters: metres(altitude))
        case .descend: return .climb(meters: -metres(altitude / 2))
        case .setAltitude: return amount == nil ? nil : .setAltitude(meters: metres(altitude))
        case .turnLeft: return .turn(degrees: -degrees(90))
        case .turnRight: return .turn(degrees: degrees(90))
        case .face: return .face(headingDegrees: direction?.degrees ?? degrees(0))
        case .moveForward: return .move(forwardMeters: metres(altitude), rightMeters: 0)
        case .moveBack: return .move(forwardMeters: -metres(altitude), rightMeters: 0)
        case .moveLeft: return .move(forwardMeters: 0, rightMeters: -metres(altitude))
        case .moveRight: return .move(forwardMeters: 0, rightMeters: metres(altitude))
        case .lookUp: return .pitch(degrees: degrees(15))
        case .lookDown: return .pitch(degrees: -degrees(15))
        case .zoomIn: return .setAltitude(meters: altitude / factor)
        case .zoomOut: return .setAltitude(meters: altitude * factor)
        }
    }
}
