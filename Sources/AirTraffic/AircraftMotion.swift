import Foundation
import simd

/// Where an aircraft is between reports: dead reckoned from its last fix
/// by its ground speed, track and vertical rate, with any jump at a new
/// report eased away rather than shown. Times are the device's seconds
/// (any monotonic clock), so the server's clock never matters.
struct AircraftMotion {
    private(set) var report: AircraftReport
    /// When the report's position was measured, device seconds.
    private(set) var fixTime: TimeInterval
    /// Added to the dead-reckoned position, decaying to nothing: the
    /// difference between where the aircraft was shown and where the new
    /// report put it, ECEF metres.
    private var correction = SIMD3<Double>.zero
    private var correctionTime: TimeInterval = 0
    /// Past positions, oldest first.
    private(set) var trail: [TrailPoint] = []

    struct TrailPoint: Equatable {
        var time: TimeInterval
        /// ECEF metres.
        var position: SIMD3<Double>
    }

    /// Dead reckoning stops this long after the fix, so a lost aircraft
    /// stops rather than flying on.
    static let maximumExtrapolation = 20.0
    /// About 95% of a correction is gone in this many seconds.
    static let easeDuration = 2.0
    /// A correction this big (metres) is a different aircraft or a bad
    /// report, not drift: it snaps, and the trail starts again.
    static let snapDistance = 3_000.0
    /// How often the trail takes a point, and how much it keeps, seconds.
    static let trailInterval = 2.0
    static let trailDuration = 180.0
    /// Radians: 30°.
    static let maximumPitch = Double.pi / 6

    init(report: AircraftReport, receivedAt now: TimeInterval) {
        self.report = report
        fixTime = now - report.positionAge
    }

    /// Takes a newer report, received at `now`. The aircraft is shown where
    /// it was, easing to the new track. Returns false for a report no newer
    /// than the last (the same position served again).
    @discardableResult
    mutating func update(with newReport: AircraftReport, receivedAt now: TimeInterval, groundHeight: Double) -> Bool {
        let newFixTime = now - newReport.positionAge
        // A second's slack: ages are rounded, and latency varies.
        guard newFixTime > fixTime + 0.5 || newReport.coordinate != report.coordinate else { return false }
        let shown = position(at: now, groundHeight: groundHeight)
        report = newReport
        fixTime = max(newFixTime, fixTime)
        let jump = shown - deadReckoned(at: now, groundHeight: groundHeight)
        if simd_length(jump) > Self.snapDistance {
            correction = .zero
            trail.removeAll()
        } else {
            correction = jump
        }
        correctionTime = now
        return true
    }

    /// Where the last report puts the aircraft at `now`, ECEF metres.
    func deadReckoned(at now: TimeInterval, groundHeight: Double) -> SIMD3<Double> {
        let (coordinate, height) = reckon(at: now, groundHeight: groundHeight)
        return Geodesy.ecef(coordinate, height: height)
    }

    /// Where to show the aircraft at `now`, ECEF metres.
    func position(at now: TimeInterval, groundHeight: Double) -> SIMD3<Double> {
        deadReckoned(at: now, groundHeight: groundHeight) + correction * remainingCorrection(at: now)
    }

    /// The fraction of the correction still applied.
    func remainingCorrection(at now: TimeInterval) -> Double {
        exp(-3 * max(now - correctionTime, 0) / Self.easeDuration)
    }

    private func reckon(at now: TimeInterval, groundHeight: Double) -> (GeoCoordinate, Double) {
        let elapsed = min(max(now - fixTime, 0), Self.maximumExtrapolation)
        var coordinate = report.coordinate
        if let speed = report.groundSpeed, let track = report.track, speed > 0 {
            coordinate = GeoMath.destination(from: coordinate, bearing: track, distance: speed * elapsed)
        }
        // Not held above the ground estimate: that's for the middle of the
        // view, and an aircraft may be over lower ground elsewhere.
        return (coordinate, (report.height ?? groundHeight) + (report.verticalRate ?? 0) * elapsed)
    }

    /// Radians clockwise from north the aircraft is drawn facing, and up
    /// from level: its track, and its climb or descent angle.
    var attitude: (heading: Double, pitch: Double) {
        let speed = report.groundSpeed ?? 0
        let climb = report.verticalRate ?? 0
        // Below walking pace the climb angle means nothing; and no aircraft
        // in these reports climbs or dives steeper than this.
        let pitch = speed > 1 ? min(max(atan2(climb, speed), -Self.maximumPitch), Self.maximumPitch) : 0
        return (report.track ?? 0, pitch)
    }

    /// Takes a trail point if one is due and drops those too old.
    mutating func sampleTrail(at now: TimeInterval, groundHeight: Double) {
        if trail.last.map({ now - $0.time >= Self.trailInterval }) ?? true {
            trail.append(TrailPoint(time: now, position: position(at: now, groundHeight: groundHeight)))
        }
        if let keep = trail.firstIndex(where: { now - $0.time <= Self.trailDuration }), keep > 0 {
            trail.removeFirst(keep)
        }
    }

    /// Whether nothing has been heard for long enough to drop the aircraft.
    func isStale(at now: TimeInterval) -> Bool {
        now - fixTime > AirTrafficTracker.staleAfter
    }
}

/// Every aircraft in view, from the reports as they arrive: merges each
/// snapshot, advances them all each frame and drops the ones no longer
/// heard from.
struct AirTrafficTracker {
    private(set) var aircraft: [String: AircraftMotion] = [:]

    /// An aircraft with no position for this long is dropped, seconds.
    static let staleAfter = 45.0

    /// What a frame draws for one aircraft.
    struct State {
        var id: String
        var callsign: String?
        var coordinate: GeoCoordinate
        /// ECEF metres.
        var position: SIMD3<Double>
        /// Radians clockwise from north, and up from level.
        var heading: Double
        var pitch: Double
        var height: Double
        var heightSource: AircraftReport.HeightSource
        var onGround: Bool
        /// Oldest first, ending at `position`, each with its age in seconds.
        var trail: [(age: Double, position: SIMD3<Double>)]
    }

    mutating func merge(_ snapshot: AirTrafficSnapshot, receivedAt now: TimeInterval, groundHeight: Double) {
        for report in snapshot.reports {
            if aircraft[report.id] == nil {
                aircraft[report.id] = AircraftMotion(report: report, receivedAt: now)
            } else {
                aircraft[report.id]?.update(with: report, receivedAt: now, groundHeight: groundHeight)
            }
        }
    }

    mutating func removeAll() { aircraft.removeAll() }

    /// Moves every aircraft to `now`, samples their trails and drops the
    /// stale ones; returns what to draw, by id.
    mutating func advance(to now: TimeInterval, groundHeight: Double) -> [State] {
        aircraft = aircraft.filter { !$0.value.isStale(at: now) }.mapValues { motion in
            var motion = motion
            motion.sampleTrail(at: now, groundHeight: groundHeight)
            return motion
        }
        return aircraft.values.map { motion in
            let position = motion.position(at: now, groundHeight: groundHeight)
            let (coordinate, height) = Geodesy.geodetic(position)
            let attitude = motion.attitude
            let trail = motion.trail.map { (age: now - $0.time, position: $0.position) } + [(age: 0, position: position)]
            return State(id: motion.report.id, callsign: motion.report.callsign, coordinate: coordinate,
                         position: position, heading: attitude.heading, pitch: attitude.pitch, height: height,
                         heightSource: motion.report.heightSource, onGround: motion.report.onGround, trail: trail)
        }
        .sorted { $0.id < $1.id }
    }
}

/// A trail split by age into bands, each drawn fainter than the last, so
/// it fades without per-vertex colour. Neighbouring bands share their
/// boundary point, so the trail stays joined.
enum TrailBands {
    /// One aircraft's trail, `points` (oldest first, with ages), cut at
    /// every `duration / bands` seconds of age: the polyline in each band,
    /// newest band first. Points older than `duration` are dropped.
    static func split(_ points: [(age: Double, position: SIMD3<Double>)],
                      bands: Int, duration: Double) -> [[SIMD3<Double>]] {
        var result = [[SIMD3<Double>]](repeating: [], count: bands)
        guard bands > 0, duration > 0 else { return result }
        func band(_ age: Double) -> Int? {
            guard age <= duration else { return nil }
            return min(Int(max(age, 0) / duration * Double(bands)), bands - 1)
        }
        for (i, point) in points.enumerated() {
            guard let b = band(point.age) else { continue }
            result[b].append(point.position)
            // The first point of a younger band also ends this one.
            if i + 1 < points.count, let next = band(points[i + 1].age), next < b {
                result[b].append(points[i + 1].position)
            }
        }
        return result
    }
}

/// How a marker is turned: its nose (−z, RealityKit's forward) along the
/// heading, pitched up by the climb angle, with its wings (x) level.
enum AircraftPose {
    /// Marker frame → ECEF, at `coordinate`. Level and facing north, this is
    /// the anchor frame there (x east, y up, z south).
    static func rotation(heading: Double, pitch: Double, at coordinate: GeoCoordinate) -> simd_quatd {
        let frame = Geodesy.enu(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let level = frame.north * cos(heading) + frame.east * sin(heading)
        let forward = level * cos(pitch) + frame.up * sin(pitch)
        let right = simd_normalize(simd_cross(forward, frame.up))
        let up = simd_cross(right, forward)
        return simd_quatd(simd_double3x3(columns: (right, up, -forward)))
    }
}
