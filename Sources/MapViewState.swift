import Foundation
import simd

/// Everything needed to put the view back as it was: the camera and
/// navigation state, ground estimates, host, room placement, held tiles and
/// the settings that shape navigation. Copied as JSON from Tuning; restored
/// from the clipboard or, at launch, from ALSOMAPS_STATE.
///
/// Version 2 is camera-centric. Older (focus, radius, Fly) states aren't
/// supported.
struct MapViewState: Codable {
    static let currentVersion = 2

    struct Camera: Codable {
        var latitude: Double
        var longitude: Double
        /// Metres above the WGS84 ellipsoid.
        var height: Double
        var headingDegrees: Double
        var pitchDegrees: Double
    }

    struct GroundEstimate: Codable {
        /// h_ray: terrain height the view ray meets, metres above the ellipsoid.
        var ray: Double
        /// h_env: the low envelope placed on the base plane.
        var envelope: Double
    }

    struct Placement: Codable {
        var translation: [Double]
        var yawDegrees: Double

        var placement: RoomPlacement {
            let t = translation.count == 3 ? SIMD3(translation[0], translation[1], translation[2]) : .zero
            return RoomPlacement(translation: t, yaw: yawDegrees * .pi / 180)
        }
    }

    var version: Int
    var camera: Camera
    var movementHeadingDegrees: Double
    var headingLink: HeadingLink
    /// "modelFlight" for now.
    var controlStyle: String
    /// "adaptiveModel" for now.
    var presentationStyle: String
    var groundEstimate: GroundEstimate
    /// MapPresentation.id: "volume" or "immersive".
    var host: String
    var roomPlacement: Placement
    /// "live" or "held".
    var tiles: String
    /// What streaming was held at, when tiles are held.
    var heldStreaming: StreamingInputs?
    var settings: StreamingSettings

    init(navigation: NavigationState, rayHeight: Double, envelopeHeight: Double, host: String,
         roomPlacement: RoomPlacement, heldStreaming: StreamingInputs?, settings: StreamingSettings) {
        let degrees = 180 / Double.pi
        version = Self.currentVersion
        camera = Camera(latitude: navigation.camera.latitude, longitude: navigation.camera.longitude,
                        height: navigation.camera.height,
                        headingDegrees: navigation.camera.heading * degrees,
                        pitchDegrees: navigation.camera.pitch * degrees)
        movementHeadingDegrees = navigation.movementHeading * degrees
        headingLink = navigation.headingLink
        controlStyle = "modelFlight"
        presentationStyle = "adaptiveModel"
        groundEstimate = GroundEstimate(ray: rayHeight, envelope: envelopeHeight)
        self.host = host
        self.roomPlacement = Placement(translation: [roomPlacement.translation.x, roomPlacement.translation.y,
                                                     roomPlacement.translation.z],
                                       yawDegrees: roomPlacement.yaw * degrees)
        tiles = heldStreaming == nil ? "live" : "held"
        self.heldStreaming = heldStreaming
        self.settings = settings
    }

    var navigationState: NavigationState {
        let radians = Double.pi / 180
        return NavigationState(camera: CameraPose(latitude: camera.latitude, longitude: camera.longitude,
                                                  height: camera.height,
                                                  heading: camera.headingDegrees * radians,
                                                  pitch: camera.pitchDegrees * radians),
                               movementHeading: movementHeadingDegrees * radians,
                               headingLink: headingLink)
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    enum ParseError: LocalizedError, Equatable {
        case notAViewState
        case unsupportedVersion
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .notAViewState: "That isn't a view state."
            case .unsupportedVersion: "That view state is from an older version of the app and can't be restored."
            case let .invalid(reason): "That view state is invalid: \(reason)."
            }
        }
    }

    /// Parses and validates a view state. Older focus-centric states are
    /// recognised and rejected with a clear message.
    static func parse(_ text: String) throws -> MapViewState {
        let data = Data(text.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notAViewState
        }
        guard let version = object["version"] as? Int else {
            throw object["radius"] != nil || object["flyScale"] != nil
                ? ParseError.unsupportedVersion : ParseError.notAViewState
        }
        guard version == currentVersion else { throw ParseError.unsupportedVersion }
        let state: MapViewState
        do {
            state = try JSONDecoder().decode(MapViewState.self, from: data)
        } catch {
            throw ParseError.invalid(String(describing: error))
        }
        try state.validate()
        return state
    }

    private func validate() throws {
        let numbers = [camera.latitude, camera.longitude, camera.height, camera.headingDegrees,
                       camera.pitchDegrees, movementHeadingDegrees, groundEstimate.ray, groundEstimate.envelope,
                       roomPlacement.yawDegrees] + roomPlacement.translation
        guard numbers.allSatisfy(\.isFinite) else { throw ParseError.invalid("non-finite numbers") }
        guard abs(camera.latitude) <= 90 else { throw ParseError.invalid("latitude out of range") }
        guard (-90...90).contains(camera.pitchDegrees) else { throw ParseError.invalid("pitch out of range") }
        guard tiles == "live" || (tiles == "held" && heldStreaming != nil) else {
            throw ParseError.invalid("tiles must be live, or held with heldStreaming")
        }
        if let held = heldStreaming {
            guard held.streamingRadius > 0, held.streamingRadius.isFinite else {
                throw ParseError.invalid("held streaming radius")
            }
        }
    }
}
