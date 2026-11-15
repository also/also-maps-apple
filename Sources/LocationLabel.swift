import Foundation
import Observation
import SwiftUI
import simd

/// Debug: names where the navigation position is ("30,000 ft over
/// Worcester") from the bundled gazetteer, shown above the reference head
/// pose in the RealityKit immersive space.
///
/// The navigation position changes every frame, but the phrase only
/// changes in steps (altitude to the nearest 500 or 1,000 ft, distances to
/// the mile or more, which place is nearest). So the pose is checked a few
/// times a second, and the gazetteer is asked again only once the pose has
/// moved far enough from the one last asked about to change the phrase, and
/// at most twice a second. Moving slowly, nothing is asked; flying fast, the
/// label is never more than about half a second behind.
@MainActor
@Observable
final class LocationLabel {
    /// "30,000 ft over Worcester".
    private(set) var description: String?
    /// "Looking toward Boston", when the view center names somewhere else.
    private(set) var lookingToward: String?

    /// How often the pose is checked.
    private static let pollInterval: Duration = .milliseconds(250)
    /// The least time between gazetteer queries.
    private static let minimumQueryInterval: Duration = .milliseconds(500)

    /// Checks `pose()` until cancelled, updating the label when it has
    /// moved enough. Run it with `.task` while the label shows.
    func run(pose: @MainActor () -> CameraPose) async {
        var lastQueried: CameraPose?
        var lastQueryTime: ContinuousClock.Instant?
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let current = pose()
            let due = lastQueryTime.map { clock.now - $0 >= Self.minimumQueryInterval } ?? true
            if due, lastQueried.map({ Self.hasMoved(from: $0, to: current) }) ?? true {
                lastQueried = current
                lastQueryTime = clock.now
                await update(for: current)
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Whether `b` is far enough from `a` that the phrase might differ:
    /// moved a twentieth of the height sideways (at least 100 m), 3% up or
    /// down, or turned the view direction (which moves the view center) by
    /// 2°.
    nonisolated static func hasMoved(from a: CameraPose, to b: CameraPose) -> Bool {
        let height = max(min(a.height, b.height), 1)
        if GeoMath.distance(from: a.coordinate, to: b.coordinate) > max(height * 0.05, 100) { return true }
        if abs(b.height - a.height) > height * 0.03 { return true }
        let turn = acos(min(max(simd_dot(a.basis.forward, b.basis.forward), -1), 1))
        return turn > 2 * .pi / 180
    }

    private func update(for pose: CameraPose) async {
        do {
            let context = try await Gazetteer.shared.context(for: pose)
            description = PlaceSuggestions.description(of: context)
            lookingToward = Self.lookingToward(context)
        } catch {
            // No Geography.sqlite, or a broken one: say so once in the label.
            description = "No place names: \(error)"
            lookingToward = nil
        }
    }

    /// "Looking toward Boston" when the view center's name differs from
    /// the name below, as PlaceSuggestions.names decides it.
    nonisolated static func lookingToward(_ context: PlaceContext) -> String? {
        let here = PlaceSuggestions.shortName(context.below, nearbyWithin: 5_000)
        guard let there = context.viewCenter.flatMap(PlaceSuggestions.aheadName),
              there != here
        else { return nil }
        return "Looking toward \(there)"
    }
}

/// The label's content: glass like the attribution, and no hit testing, so
/// a pinch while looking at it goes through to the map.
struct LocationLabelView: View {
    let label: LocationLabel

    var body: some View {
        if let description = label.description {
            VStack(spacing: 2) {
                Text(description).font(.title2)
                if let lookingToward = label.lookingToward {
                    Text(lookingToward).font(.body).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .glassBackgroundEffect()
            .allowsHitTesting(false)
        }
    }
}
