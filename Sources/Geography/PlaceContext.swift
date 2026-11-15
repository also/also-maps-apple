import Foundation

/// Facts about where the camera is and what it's looking at, with no wording
/// attached. PlaceSuggestions builds phrases from it, and tests can
/// construct one directly.
struct PlaceContext: Codable, Equatable {
    var camera: Camera
    /// The point directly below the camera.
    var below: Surroundings
    /// The point at the center of the view, when the camera looks at the
    /// ground somewhere other than straight down.
    var viewCenter: ViewCenter?

    struct Camera: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        /// Meters above the WGS84 ellipsoid.
        var height: Double
        /// Degrees clockwise from north.
        var heading: Double
    }

    struct ViewCenter: Codable, Equatable {
        var surroundings: Surroundings
        /// Meters from the point below the camera.
        var distance: Double
        /// Degrees clockwise from north, from the point below the camera.
        var bearing: Double
        /// The place the camera looks toward, measured from the view center:
        /// ahead of the camera and not far beyond the view center. Nil when
        /// no significant place is, and the view center's state or water
        /// names it instead.
        var ahead: Nearby?
    }

    struct Surroundings: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        /// The most specific significant place whose urban area contains the
        /// point.
        var urbanArea: Feature?
        /// Significant places nearby, most relevant first.
        var nearby: [Nearby]
        /// The state or province containing the point.
        var state: Region?
        /// Named waters containing the point, most specific first.
        var waters: [Region]
    }

    struct Feature: Codable, Equatable {
        /// Natural Earth's `ne_id`.
        var id: Int
        var wikidata: String?
        /// The name used in English phrases.
        var name: String
        /// Natural Earth's own name, when it differs.
        var localName: String?
        /// Natural Earth's feature class: "Admin-0 capital", "Populated place", …
        var kind: String
        var state: String?
        var country: String?
        var countryCode: String?
        var population: Int?
        /// Natural Earth's scale rank: 0 for the most significant places, 10 for the least.
        var rank: Int
    }

    struct Nearby: Codable, Equatable {
        var place: Feature
        /// Meters from the point.
        var distance: Double
        /// Degrees clockwise from north, from the place to the point: 270
        /// means the point is west of the place.
        var bearingFromPlace: Double
    }

    struct Region: Codable, Equatable {
        var id: Int
        var wikidata: String?
        var name: String
        var localName: String?
        /// "State", "Province", "County", … for states; "ocean", "sea",
        /// "bay", … for waters.
        var kind: String?
        var country: String?
        var countryCode: String?
        /// Whether a populated place in the same country has the same name:
        /// the province of Málaga and the city of Málaga, New York State and
        /// New York City.
        var sharesNameWithPlace = false
    }
}
