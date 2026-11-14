// tvOS has no Geography (Natural Earth names) and doesn't save places.
#if !os(tvOS)
import Foundation

/// Names offered for a place being saved, from the gazetteer
/// (Sources/Geography): what's below the navigation position and what's at
/// the center of what's shown.
enum PlaceNamer {
    /// The fixed phrases (PlaceSuggestions), best first. The coordinates
    /// when the gazetteer can't load.
    static func suggestions(for place: Place, viewCenter: GeoCoordinate?) async -> [String] {
        let camera = PlaceContext.Camera(latitude: place.latitude, longitude: place.longitude,
                                         height: place.position?.height ?? 0, heading: place.heading)
        let names = (try? await Gazetteer.shared.context(camera: camera, viewCenter: viewCenter))
            .map(PlaceSuggestions.names(for:)) ?? []
        return names.isEmpty ? [PlaceLink.coordinateName(place.latitude, place.longitude)] : names
    }
}
#endif
