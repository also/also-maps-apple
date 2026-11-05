import SwiftUI
import UniformTypeIdentifiers

/// The Route menu, shared by the visionOS volume, the Mac and iPhone:
/// open a route file, choose how it's coloured and where its heights come
/// from, replay it, and close it. Only shown while imported routes are on
/// (ViewPreferences.importsRoutes). The host supplies what needs its map
/// (framing the route again, and the replay) and presents the file
/// importer with `routeImporter`, on a view that outlives the menu: a
/// toolbar may rebuild its items, dropping one's state.
struct RouteMenu: View {
    let routes: RouteSession
    @Binding var importing: Bool
    var frame: () -> Void
    var setReplaying: (Bool) -> Void

    /// GPX (declared as XML, which some apps type it as), GeoJSON and JSON.
    static let contentTypes: [UTType] = [
        UTType(filenameExtension: "gpx", conformingTo: .xml),
        UTType(filenameExtension: "geojson", conformingTo: .json),
        .json,
        .xml,
    ].compactMap { $0 }

    var body: some View {
        @Bindable var routes = routes
        Menu("Route", systemImage: "figure.walk") {
            Button("Open Route…", systemImage: "doc") { importing = true }
            if let route = routes.route {
                Picker("Colour by", selection: $routes.colouring) {
                    ForEach(RouteColouring.allCases.filter { $0.isAvailable(for: route) }) { colouring in
                        Text(colouring.name).tag(colouring)
                    }
                }
                Picker("Height", selection: $routes.heightMode) {
                    ForEach(RouteHeightMode.allCases) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                Divider()
                Button(routes.isReplaying ? "Stop Replay" : "Replay",
                       systemImage: routes.isReplaying ? "stop.fill" : "play.fill") {
                    setReplaying(!routes.isReplaying)
                }
                Picker("Replay speed", selection: $routes.speedup) {
                    ForEach(RouteSession.speedups, id: \.self) { speedup in
                        Text("\(Int(speedup))×").tag(speedup)
                    }
                }
                Button("Show Whole Route", systemImage: "arrow.up.left.and.arrow.down.right") { frame() }
                    .disabled(routes.isReplaying)
                Divider()
                Button("Close Route", systemImage: "xmark") { routes.close() }
            }
        }
    }
}

extension View {
    /// The Route menu's file importer: `open` gets the chosen file, which
    /// may be security-scoped (RouteSession.open handles that).
    func routeImporter(isPresented: Binding<Bool>, open: @escaping (URL) -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: RouteMenu.contentTypes) { result in
            switch result {
            case let .success(url): open(url)
            case let .failure(error): print("[AlsoMaps] no route chosen: \(error.localizedDescription)")
            }
        }
    }
}

/// The open route's name, what its colours mean, and how the replay and
/// draping are going; or why a file didn't open. Shown beside the map's
/// attribution, never in place of it.
struct RouteLegend: View {
    let routes: RouteSession

    var body: some View {
        if let route = routes.route {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(route.name) · \(Self.distance(route.length))")
                    .font(.caption.bold())
                    .lineLimit(1)
                if let scale = routes.scale {
                    HStack(spacing: 6) {
                        Text(routes.colouring.name)
                        Text(routes.colouring.label(scale.lower))
                        HStack(spacing: 0) {
                            ForEach(0..<RouteColourScale.binCount, id: \.self) { bin in
                                Self.colour(bin).frame(width: 14, height: 8)
                            }
                        }
                        .clipShape(.capsule)
                        Text(routes.colouring.label(scale.upper))
                    }
                    .font(.caption2.monospacedDigit())
                }
                if routes.isReplaying {
                    Text("Replay \(TrackSession.minutes(routes.replayElapsed)) / \(TrackSession.minutes(routes.replayDuration)) · \(Int(routes.speedup))×")
                        .font(.caption2.monospacedDigit())
                }
                if routes.drapeProgress < 1 {
                    Text("Placing on the ground… \(Int(routes.drapeProgress * 100))%")
                        .font(.caption2.monospacedDigit())
                }
            }
        } else if let message = routes.errorMessage {
            Text(message)
                .font(.caption)
                .lineLimit(2)
        }
    }

    static func colour(_ bin: Int) -> Color {
        let c = RouteColourScale.colours[bin]
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    static func distance(_ metres: Double) -> String {
        metres < 1_000 ? String(format: "%.0f m", metres) : String(format: "%.1f km", metres / 1_000)
    }
}
