// tvOS has no Geography (Natural Earth names) and doesn't save places.
#if !os(tvOS)
import Foundation

/// Names offered for a view being saved, from the gazetteer (Sources/Geography):
/// what's below the camera and what it's looking at.
enum PlaceNamer {
    /// The fixed phrases (PlaceSuggestions), best first. The coordinates
    /// when the gazetteer can't load.
    static func suggestions(for place: Place, camera: CameraPose) async -> [String] {
        let names = (try? await Gazetteer.shared.context(camera: Self.camera(camera), viewCenter: place.coordinate))
            .map(PlaceSuggestions.names(for:)) ?? []
        return names.isEmpty ? [PlaceLink.coordinateName(place.latitude, place.longitude)] : names
    }

    private static func camera(_ pose: CameraPose) -> PlaceContext.Camera {
        PlaceContext.Camera(latitude: pose.latitude, longitude: pose.longitude, height: pose.height,
                            heading: pose.heading * 180 / .pi)
    }
}
#endif
