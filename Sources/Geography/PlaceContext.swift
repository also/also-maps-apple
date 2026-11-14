import Foundation

/// Facts about where the camera is and what it's looking at, with no wording
/// attached. Phrases (PlaceSuggestions) and the on-device model
/// (PlaceNameModel) are both built from it, and tests can construct one
/// directly.
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
    }
}

extension PlaceContext.Surroundings {
    /// Every place and region name in these surroundings.
    var allNames: [String] {
        var names: [String] = []
        if let urbanArea { names += [urbanArea.name, urbanArea.localName].compactMap { $0 } }
        for n in nearby { names += [n.place.name, n.place.localName, n.place.state, n.place.country].compactMap { $0 } }
        for r in [state].compactMap({ $0 }) + waters { names += [r.name, r.localName, r.country].compactMap { $0 } }
        return names
    }
}

extension PlaceContext {
    /// Every place and region name in the context.
    var allNames: [String] {
        below.allNames + (viewCenter?.surroundings.allNames ?? [])
    }
}
