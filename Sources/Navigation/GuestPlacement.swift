import Foundation
import simd

/// How a guest place is shown with the map.
enum GuestMode: String, Codable, CaseIterable, Identifiable {
    /// Beside the map's centre, at its own heights, so differences in
    /// elevation show.
    case sideBySide = "side"
    /// On the map's centre, turned to a heading, with its ground level on
    /// the map's, to compare sizes.
    case overlay

    var id: Self { self }

    var name: String {
        switch self {
        case .sideBySide: "Side by Side"
        case .overlay: "Overlay"
        }
    }

    /// ALSOMAPS_GUEST_MODE's values: `side` (or `side-by-side`) and `overlay`.
    init?(environmentValue value: String) {
        switch value.lowercased() {
        case "side", "side-by-side", "sidebyside": self = .sideBySide
        case "overlay": self = .overlay
        default: return nil
        }
    }
}

/// Where a second ("guest") place is shown in the host's world: a rigid
/// transform taking the guest's local frame at its centre to a point in the
/// host's, at real size, with no map projection in between. The guest
/// streams around its own centre; only where its tiles are drawn changes.
///
/// The host's centre is fixed when the guest is set (the view's centre
/// then, or the place gone to), so the guest stays put in the host's world
/// while you fly to it or around it.
struct GuestPlacement: Equatable {
    var mode: GuestMode
    /// The host's centre and half-width when the guest was set.
    var hostCentre: GeoCoordinate
    var hostRadius: Double
    /// The guest's centre, and the half-width of what it streams, metres.
    var guestCentre: GeoCoordinate
    var guestRadius: Double
    /// Where the guest's north points in the host, radians clockwise from
    /// north. Both modes; 0 keeps north as north.
    var heading = 0.0
    /// Side by side: the direction from the host's centre to the guest's,
    /// radians clockwise from north. East by default.
    var bearing = Double.pi / 2
    /// Side by side: the gap between the two areas, metres; nil for the
    /// default (`defaultGap`).
    var gap: Double?
    /// Overlay: ground heights sampled while running, metres above the
    /// ellipsoid, nil until known. Never saved (Google's terms: heights are
    /// derived from tile content).
    var hostGround: Double?
    var guestGround: Double?

    /// A tenth of the two radii together, at least 100 m.
    var defaultGap: Double { max(100, 0.1 * (hostRadius + guestRadius)) }

    /// How far apart the centres are side by side: both radii and the gap,
    /// so the two squares don't overlap (unless the guest is turned, when
    /// its corners can reach a little further).
    var separation: Double { hostRadius + guestRadius + (gap ?? defaultGap) }

    /// Where the guest's centre is shown, in the host's world.
    var shownCentre: GeoCoordinate {
        switch mode {
        case .sideBySide:
            GeoMath.destination(from: hostCentre, bearing: bearing, distance: separation)
        case .overlay:
            hostCentre
        }
    }

    /// How far the guest is raised where it's shown, metres. Side by side,
    /// none: a guest point h metres above the ellipsoid is shown h metres
    /// above it. Overlay, enough to put the guest's ground on the host's.
    var verticalShift: Double {
        switch mode {
        case .sideBySide:
            0
        case .overlay:
            (hostGround ?? 0) - (guestGround ?? 0)
        }
    }

    /// Whether the guest can be drawn yet: an overlay waits for both ground
    /// samples, or it would show at its own heights first and then jump.
    var isPlaced: Bool {
        mode == .sideBySide || (hostGround != nil && guestGround != nil)
    }

    /// Where the guest streams from: its centre, on the ellipsoid. The
    /// height only sets the origin tiles are measured from; the shift above
    /// is what moves them.
    var guestAnchor: StreamingAnchor { StreamingAnchor(coordinate: guestCentre) }

    /// The guest's real world (ECEF) → where it's shown in the host's
    /// (ECEF): out of the guest's level frame at its centre, turned about
    /// its up, into the level frame at the shown centre, raised by the
    /// shift. Rigid.
    var shownFromReal: Similarity {
        let real = guestAnchor.ecefFromAnchor
        let shown = StreamingAnchor(coordinate: shownCentre, height: verticalShift).ecefFromAnchor
        // Anchor frames are x east, y up, z south. Turning clockwise seen
        // from above is negative about +y.
        let turn = Similarity(rotation: simd_quatd(angle: -heading, axis: SIMD3(0, 1, 0)))
        return shown.after(turn).after(real.inverse)
    }

    /// The guest's stream: around its own centre, shown here.
    var stream: DisplacedStream {
        DisplacedStream(anchor: guestAnchor, streamingRadius: guestRadius, shownFromReal: shownFromReal)
    }

    /// Ground samples for an overlay cover this radius around each centre
    /// (the bridge samples 0.8 × it and takes the lowest), so it's the
    /// ground near the middle that's matched, not the lowest valley in the
    /// whole area.
    static func groundSampleRadius(guestRadius: Double) -> Double {
        min(max(0.25 * guestRadius, 50), 2_000)
    }
}
