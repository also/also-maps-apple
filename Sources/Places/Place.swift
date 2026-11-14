import Foundation

/// A place to go to, in one of two forms (docs/fundamentals.md, "Navigation
/// position"):
///
/// - What you're looking at: `latitude` and `longitude` are the center of
///   what's shown, `radius` how much is shown around it, and `heading` the
///   way the view faces. Built-in places, place links and points from
///   other tools.
/// - Where you are (`position` set): `latitude`, `longitude` and
///   `position.height` are the navigation position itself, and `heading`
///   its heading. Places saved to My Map. `radius` isn't used.
struct Place: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var latitude: Double
    var longitude: Double
    /// View half-width, meters. Not used when `position` is set.
    var radius: Double
    /// Degrees clockwise from north: the way the view faces, or the
    /// navigation position's heading.
    var heading: Double = 0
    /// Set when the place is a navigation position.
    var position: Position? = nil

    struct Position: Codable, Hashable {
        /// Meters above the WGS84 ellipsoid.
        var height: Double
        /// Degrees, 0 level, −90 straight down, when it was saved on a flat
        /// screen, where the navigation position's pitch is what's shown.
        /// visionOS's tilt comes from the height, so it saves none.
        var pitch: Double? = nil
    }

    var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }

    private enum CodingKeys: String, CodingKey { case id, name, latitude, longitude, radius, heading, position }

    init(id: String, name: String, latitude: Double, longitude: Double, radius: Double, heading: Double = 0) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.heading = heading
    }

    /// A navigation position as a place: heading in degrees.
    init(id: String, name: String, position pose: CameraPose, savesPitch: Bool) {
        self.init(id: id, name: name, latitude: pose.latitude, longitude: pose.longitude,
                  radius: PlaceLink.defaultRadius, heading: Self.degrees(pose.heading))
        position = Position(height: pose.height, pitch: savesPitch ? pose.pitch * 180 / .pi : nil)
    }

    /// `place` with another id.
    init(copying place: Place, id: String) {
        self.init(id: id, name: place.name, latitude: place.latitude, longitude: place.longitude,
                  radius: place.radius, heading: place.heading)
        position = place.position
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        radius = try c.decode(Double.self, forKey: .radius)
        heading = try c.decodeIfPresent(Double.self, forKey: .heading) ?? 0
        position = try c.decodeIfPresent(Position.self, forKey: .position)
    }

    /// The navigation position this place is, with `pitch` (radians) when
    /// it saved none; nil for a place that's what you're looking at.
    func pose(pitch: Double) -> CameraPose? {
        guard let position else { return nil }
        return CameraPose(latitude: latitude, longitude: longitude, height: position.height,
                          heading: heading * .pi / 180,
                          pitch: position.pitch.map { $0 * .pi / 180 } ?? pitch)
    }

    /// Radians to degrees in 0 ..< 360.
    private static func degrees(_ radians: Double) -> Double {
        let d = (radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }
}

/// The suggested places: the remote config's, or the defaults bundled in
/// Places.json without one. The user's own places are in PlaceStore.
enum PlaceLibrary {
    static let defaults: [Place] = {
        guard let url = Bundle.main.url(forResource: "Places", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("Places.json missing from the app bundle")
            return []
        }
        do {
            return try JSONDecoder().decode([Place].self, from: data)
        } catch {
            assertionFailure("Places.json is invalid: \(error)")
            return []
        }
    }()

    /// The list can change while the app runs, so hold on to a place's id
    /// rather than its position.
    @MainActor static var all: [Place] { AppConfigStore.shared.config?.places ?? defaults }
}
