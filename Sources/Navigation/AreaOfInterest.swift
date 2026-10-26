import Foundation
import simd

/// What streams: a square around a centre, turned to a heading. The centre
/// is also the streaming anchor. See docs/camera-core.md §7.
enum AOIPolicy: Codable, Equatable {
    /// Around the georeference point, `regionMultiplier` × the shown region.
    case georeference(regionMultiplier: Double)
    /// All around the ground beneath the viewer, so turning reveals no gaps.
    case viewer(reachPerAltitude: Double)
    /// Ahead of the viewer along the view heading, by `lead` × the reach.
    case forward(reachPerAltitude: Double, lead: Double)
    /// Around the viewer near the ground, moving to the georeference point
    /// between 1 km and 50 km above it.
    case blended(reachPerAltitude: Double, regionMultiplier: Double)
}

struct AreaOfInterest: Equatable {
    var centre: GeoCoordinate
    /// Half-width, metres.
    var radius: Double
    /// Radians clockwise from north.
    var heading: Double
}

extension AOIPolicy {
    /// Smallest reach around the viewer, metres.
    static let minimumReach = 1_000.0

    /// The area for a viewer above `viewerNadir` at `altitude` metres,
    /// looking along `heading`, with the georeference point at
    /// `georeferencePoint` and `shownRadius` metres of world shown.
    func area(viewerNadir: GeoCoordinate, altitude: Double, heading: Double,
              georeferencePoint: GeoCoordinate, shownRadius: Double) -> AreaOfInterest {
        func reach(_ perAltitude: Double) -> Double {
            let altitude = max(altitude, 0)
            let horizon = (2 * GeoMath.earthRadius * altitude + altitude * altitude).squareRoot()
            return min(max(perAltitude * altitude, Self.minimumReach), max(horizon, Self.minimumReach))
        }
        switch self {
        case let .georeference(multiplier):
            return AreaOfInterest(centre: georeferencePoint, radius: shownRadius * multiplier, heading: heading)
        case let .viewer(perAltitude):
            return AreaOfInterest(centre: viewerNadir, radius: reach(perAltitude), heading: heading)
        case let .forward(perAltitude, lead):
            let r = reach(perAltitude)
            let centre = GeoMath.destination(from: viewerNadir, bearing: heading, distance: lead * r)
            return AreaOfInterest(centre: centre, radius: r * (1 + lead), heading: heading)
        case let .blended(perAltitude, multiplier):
            let t = min(max(log(max(altitude, 1) / 1_000) / log(50.0), 0), 1)
            let w = t * t * (3 - 2 * t)
            let separation = GeoMath.distance(from: viewerNadir, to: georeferencePoint)
            let centre = separation > 0
                ? GeoMath.destination(from: viewerNadir,
                                      bearing: GeoMath.bearing(from: viewerNadir, to: georeferencePoint),
                                      distance: w * separation)
                : viewerNadir
            // Cover the viewer's surroundings (fading out) and the shown region.
            let aroundViewer = w * separation + (1 - w) * reach(perAltitude)
            let aroundShown = (1 - w) * separation + shownRadius * multiplier
            return AreaOfInterest(centre: centre, radius: max(aroundViewer, aroundShown), heading: heading)
        }
    }
}

/// A loaded tile's extent and height range, for ground estimates without
/// the network. See docs/camera-core.md §8.
struct TileHeightRange: Equatable {
    /// Centre of the tile's geometry, ECEF.
    var centre: SIMD3<Double>
    /// Distance from the centre to its farthest vertex, metres.
    var radius: Double
    /// Lowest and highest vertex, metres above the ellipsoid.
    var minimumHeight: Double
    var maximumHeight: Double
}

enum GroundStatistic: String, Codable, CaseIterable {
    case minimum
    /// The 10th percentile, ignoring isolated pits.
    case lowPercentile
}

enum GroundEstimates {
    /// How far the Earth's surface falls below the tangent plane `distance`
    /// metres away, capped at a hemisphere.
    static func curvatureDrop(_ distance: Double) -> Double {
        GeoMath.earthRadius * (1 - cos(min(distance / GeoMath.earthRadius, .pi / 2)))
    }

    /// A representative ground height at `coordinate`: the lowest vertex of
    /// the most detailed tile over that column, or nil if none covers it.
    static func columnHeight(_ tiles: [TileHeightRange], at coordinate: GeoCoordinate) -> Double? {
        var best: TileHeightRange?
        for tile in tiles where horizontalDistance(tile, coordinate) < tile.radius {
            if best == nil || tile.radius < best!.radius { best = tile }
        }
        return best?.minimumHeight
    }

    /// The low envelope of the ground within `radius` metres of `coordinate`,
    /// measured along the up there (so the Earth's curve counts), or nil if
    /// no tile reaches the footprint.
    static func envelope(_ tiles: [TileHeightRange], around coordinate: GeoCoordinate, radius: Double,
                         statistic: GroundStatistic) -> Double? {
        var heights: [Double] = []
        for tile in tiles {
            let distance = horizontalDistance(tile, coordinate)
            guard distance < radius + tile.radius else { continue }
            heights.append(tile.minimumHeight - curvatureDrop(max(distance - tile.radius, 0)))
        }
        guard !heights.isEmpty else { return nil }
        switch statistic {
        case .minimum:
            return heights.min()
        case .lowPercentile:
            heights.sort()
            return heights[Int(Double(heights.count - 1) * 0.1)]
        }
    }

    private static func horizontalDistance(_ tile: TileHeightRange, _ coordinate: GeoCoordinate) -> Double {
        GeoMath.distance(from: Geodesy.geodetic(tile.centre).coordinate, to: coordinate)
    }
}

/// A height that eases toward its latest target, ignoring changes smaller
/// than a hysteresis band.
struct EasedHeight: Equatable {
    var value: Double
    private(set) var target: Double?

    init(_ value: Double) { self.value = value }

    mutating func aim(at newTarget: Double, hysteresis: Double = 0) {
        guard newTarget.isFinite else { return }
        if abs(newTarget - (target ?? value)) > hysteresis { target = newTarget }
    }

    /// Exponential approach: about 95% of the way in `halfLife95` seconds.
    /// Snaps once within `snap`. Returns whether the value changed.
    @discardableResult
    mutating func ease(deltaTime: Double, halfLife95: Double = 0.5, snap: Double = 1e-3) -> Bool {
        guard let target else { return false }
        let remaining = target - value
        if abs(remaining) <= snap {
            value = target
            self.target = nil
        } else {
            value += remaining * min(1, deltaTime * 3 / halfLife95)
        }
        return true
    }

    mutating func reset(to newValue: Double) {
        value = newValue
        target = nil
    }
}
