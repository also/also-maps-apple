import Foundation

/// A saved view: where to look, how much to show, and which way to face.
struct Place: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var latitude: Double
    var longitude: Double
    /// View half-width, metres.
    var radius: Double
    /// Direction the volume's front faces, degrees clockwise from north.
    var heading: Double = 0

    var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }

    private enum CodingKeys: String, CodingKey { case id, name, latitude, longitude, radius, heading }

    init(id: String, name: String, latitude: Double, longitude: Double, radius: Double, heading: Double = 0) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.heading = heading
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        radius = try c.decode(Double.self, forKey: .radius)
        heading = try c.decodeIfPresent(Double.self, forKey: .heading) ?? 0
    }
}

/// The places offered in the app. Today that's the defaults bundled in
/// Places.json; user-added places (stored locally or in iCloud) would be a
/// second source merged in here.
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

    static var all: [Place] { defaults }
}
