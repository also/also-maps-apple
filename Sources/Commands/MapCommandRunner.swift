import Foundation
import MapKit

/// Carries out commands on a map: looks up named places (saved places
/// first, then a map search), then hands the map a place or a motion.
/// Shared by every command source.
@MainActor
final class MapCommandRunner {
    weak var target: MapCommandTarget?

    init(target: MapCommandTarget? = nil) {
        self.target = target
    }

    func run(_ command: MapCommand) async -> MapCommandResult {
        guard let target else { return MapCommandResult(command: command, ok: false, detail: "No map") }
        switch command {
        case let .goTo(destination):
            do {
                let place = try await Self.resolve(destination)
                target.go(to: place)
                return MapCommandResult(command: command, ok: true,
                                        detail: String(format: "%@ (%.5f, %.5f, %.0f m across)", place.name,
                                                       place.latitude, place.longitude, place.radius * 2))
            } catch {
                return MapCommandResult(command: command, ok: false, detail: error.localizedDescription)
            }
        default:
            guard let motion = CommandMotion(command, camera: target.commandCamera,
                                             altitude: target.commandAltitude)
            else { return MapCommandResult(command: command, ok: false, detail: "Not a motion") }
            target.begin(motion)
            return MapCommandResult(command: command, ok: true, detail: Self.describe(motion))
        }
    }

    private static func describe(_ motion: CommandMotion) -> String {
        var parts: [String] = []
        if motion.climb != 0 { parts.append(String(format: "Δheight %+.0f m", motion.climb)) }
        if motion.turn != 0 { parts.append(String(format: "Δheading %+.0f°", motion.turn * 180 / .pi)) }
        if motion.forward != 0 || motion.right != 0 {
            parts.append(String(format: "Δposition %.0f m fwd, %.0f m right", motion.forward, motion.right))
        }
        if motion.pitch != 0 { parts.append(String(format: "Δpitch %+.0f°", motion.pitch * 180 / .pi)) }
        return parts.isEmpty ? "No change" : parts.joined(separator: ", ")
    }

    // MARK: Places

    enum LookupError: LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case let .notFound(query): "Couldn’t find “\(query)”"
            }
        }
    }

    /// A saved place whose id or name matches, else the first map search
    /// result, framed to its region.
    static func resolve(_ destination: MapDestination) async throws -> Place {
        switch destination {
        case let .coordinate(latitude, longitude, radius):
            return Place(id: "command", name: String(format: "%.4f, %.4f", latitude, longitude),
                         latitude: latitude, longitude: longitude, radius: radius ?? 1_000)
        case let .named(query):
            if let saved = PlaceLibrary.place(named: query, in: PlaceLibrary.all) { return saved }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = [.address, .pointOfInterest, .physicalFeature]
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else { throw LookupError.notFound(query) }
            let coordinate = item.location.coordinate
            return Place(id: "search", name: item.name ?? query,
                         latitude: coordinate.latitude, longitude: coordinate.longitude,
                         radius: radius(for: item, region: response.boundingRegion))
        }
    }

    /// Half-width for a search result: a single result's region is the
    /// thing itself (a city is big, a building small), clamped to sensible
    /// views.
    private static func radius(for item: MKMapItem, region: MKCoordinateRegion) -> Double {
        let metresPerDegree = 111_000.0
        let span = max(region.span.latitudeDelta,
                       region.span.longitudeDelta * cos(region.center.latitude * .pi / 180))
        let fromRegion = span * metresPerDegree / 2
        let fallback = item.pointOfInterestCategory == nil ? 3_000.0 : 400.0
        let radius = fromRegion.isFinite && fromRegion > 0 ? fromRegion : fallback
        return min(max(radius, 300), 200_000)
    }
}
