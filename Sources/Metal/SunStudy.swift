import CoreLocation
import Foundation
import Metal
import Observation
import simd

/// The clay model and sun study (notes/clay-and-sun.md): which looks are on
/// and the chosen date and time. Only the Metal renderer draws them; each
/// Metal host asks for a frame's `lighting` and passes it to
/// MetalTileRenderer. Everything is off by default, and with everything off
/// `lighting` is nil and the renderer draws as it always has.
@MainActor
@Observable
final class SunStudy {
    static let shared = SunStudy()

    /// UserDefaults keys for Settings › General's toggles.
    static let clayKey = "ClayModel"
    static let shadowsKey = "SunShadows"
    static let shadowsOverTexturesKey = "SunShadowsOverTextures"
    static let sunPathKey = "SunPath"

    /// Each setting, or its ALSOMAPS_* variable set to 1, which turns it on
    /// for a run (ALSOMAPS_CLAY, ALSOMAPS_SHADOWS, ALSOMAPS_SHADOWS_TEXTURED,
    /// ALSOMAPS_SUN_PATH).
    static var clay: Bool { isOn(clayKey, "ALSOMAPS_CLAY") }
    static var shadows: Bool { isOn(shadowsKey, "ALSOMAPS_SHADOWS") }
    static var shadowsOverTextures: Bool { isOn(shadowsOverTexturesKey, "ALSOMAPS_SHADOWS_TEXTURED") }
    static var sunPath: Bool { isOn(sunPathKey, "ALSOMAPS_SUN_PATH") }

    private static func isOn(_ key: String, _ variable: String) -> Bool {
        ProcessInfo.processInfo.environment[variable] == "1" || UserDefaults.standard.bool(forKey: key)
    }

    /// The chosen instant, in the place's zone. Starts at now, or at
    /// ALSOMAPS_SUN_TIME (ISO 8601, say 2024-12-21T09:00:00+01:00) for a
    /// repeatable run. Not saved: each launch starts from now.
    private(set) var clock: SunClock
    /// Whether `clock.timeZone` is only the longitude's hour (SunClock's
    /// approximation), while the place's real zone is looked up or if the
    /// lookup failed.
    private(set) var timeZoneIsApproximate = true
    /// The place's name for the zone, for the controls' label.
    var timeZoneLabel: String {
        let zone = clock.timeZone
        let name = timeZoneIsApproximate ? "UTC" + Self.offset(zone.secondsFromGMT(for: clock.instant))
            : zone.localizedName(for: zone.isDaylightSavingTime(for: clock.instant) ? .shortDaylightSaving
                                 : .shortStandard, locale: .current) ?? zone.identifier
        return timeZoneIsApproximate ? "\(name), from longitude" : name
    }

    /// The controls' time of day and day (SunClock's, in the place's zone).
    /// Setting either means the study is no longer "now": a later zone
    /// change keeps the wall-clock time chosen instead of the instant.
    var minutesOfDay: Double {
        get { clock.minutesOfDay }
        set { clock.minutesOfDay = newValue; followsNow = false }
    }
    var day: Date {
        get { clock.day }
        set { clock.day = newValue; followsNow = false }
    }

    /// Time-lapse: the chosen day plays at `playbackRate`, looping.
    var isPlaying = false {
        didSet {
            lastAdvance = nil
            if isPlaying { followsNow = false }
        }
    }
    /// Seconds of the study's day per second: a day in 36 s.
    let playbackRate = 2400.0

    /// Until the time is changed, a new zone keeps the instant (now, or
    /// ALSOMAPS_SUN_TIME) rather than its wall-clock time.
    @ObservationIgnored private var followsNow = true
    @ObservationIgnored private var lastAdvance: Date?
    /// Where the zone was last looked up for; looked up again after moving
    /// `timeZoneRefetchDistance` from it.
    @ObservationIgnored private var timeZoneLookedUpAt: GeoCoordinate?
    @ObservationIgnored private var timeZoneLookup: Task<Void, Never>?
    private let timeZoneRefetchDistance = 25_000.0
    /// The day's path, cached by day and (rounded) place.
    @ObservationIgnored private var pathCache: (key: SIMD3<Double>, path: [(date: Date, position: SolarPosition)])?

    private init() {
        let start = ProcessInfo.processInfo.environment["ALSOMAPS_SUN_TIME"]
            .flatMap { try? Date($0, strategy: .iso8601) } ?? Date()
        clock = SunClock(instant: start, timeZone: .gmt)
    }

    /// Back to now, keeping the place's zone.
    func resetToNow() {
        clock.instant = Date()
        lastAdvance = nil
        followsNow = true
    }

    private func setTimeZone(_ zone: TimeZone) {
        if followsNow {
            clock.timeZone = zone
        } else {
            clock.changeTimeZone(to: zone)
        }
    }

    // MARK: A frame's lighting

    /// The frame's lighting for tiles streamed around `anchor`, or nil with
    /// every look off. Advances a playing time-lapse by the time since the
    /// last call, so calling it more than once a frame is harmless.
    func lighting(anchor: StreamingAnchor, streamingRadius: Double,
                  now: Date = Date()) -> MetalTileRenderer.Lighting? {
        let clay = Self.clay, shadows = Self.shadows, sunPath = Self.sunPath
        let shadowsOverTextures = shadows && Self.shadowsOverTextures
        guard clay || shadows || sunPath else { return nil }
        updateTimeZone(for: anchor.coordinate)
        if isPlaying {
            if let lastAdvance { clock.advance(by: min(now.timeIntervalSince(lastAdvance), 0.25) * playbackRate) }
            lastAdvance = now
        }

        let coordinate = anchor.coordinate
        let sun = SolarPosition(date: clock.instant, latitude: coordinate.latitude, longitude: coordinate.longitude)
        let elevation = sun.apparentElevation
        // Direct light fades in as the disc clears the horizon; the sky's
        // light through civil twilight (the sun 6° down).
        let strength = Float(Self.smoothstep(-1, 3, elevation))
        let daylight = Float(Self.smoothstep(-6, 6, elevation))
        let golden = Float(Self.smoothstep(0, 25, elevation))

        var lighting = MetalTileRenderer.Lighting()
        lighting.clay = clay
        lighting.shadows = shadows
        lighting.shadowsOverTextures = shadowsOverTextures
        lighting.toSun = SIMD3<Float>(sun.anchorFrame)
        lighting.sunStrength = strength
        // Warm near the horizon, near white high up; the hemisphere's sky
        // and ground go dark through twilight. Linear, tuned by eye only.
        lighting.sunColour = simd_mix(SIMD3<Float>(1, 0.55, 0.3), SIMD3<Float>(1, 0.96, 0.9),
                                      SIMD3(repeating: golden)) * 0.9
        lighting.skyColour = simd_mix(SIMD3<Float>(0.02, 0.025, 0.05), SIMD3<Float>(0.3, 0.34, 0.4),
                                      SIMD3(repeating: daylight))
        lighting.groundColour = simd_mix(SIMD3<Float>(0.005, 0.005, 0.01), SIMD3<Float>(0.14, 0.12, 0.1),
                                         SIMD3(repeating: daylight))
        let sky = simd_mix(SIMD3<Double>(0.01, 0.012, 0.03),
                           SIMD3(MetalTileRenderer.skyColour.red, MetalTileRenderer.skyColour.green,
                                 MetalTileRenderer.skyColour.blue), SIMD3(repeating: Double(daylight)))
        lighting.clearColour = MTLClearColorMake(sky.x, sky.y, sky.z, 1)
        // The square the area of interest streams, capped: past a couple of
        // kilometres a 2048² map's texels are bigger than buildings.
        lighting.shadowRadius = min(streamingRadius * 2.0.squareRoot(), Self.environment("ALSOMAPS_SHADOW_RADIUS") ?? 1500)
        lighting.shadowResolution = Int(min(max(Self.environment("ALSOMAPS_SHADOW_RESOLUTION") ?? 2048, 256), 8192))
        if sunPath {
            lighting.sunPath = sunPathDots(coordinate: coordinate, current: sun,
                                           radius: min(max(streamingRadius * 0.8, 50), 5000))
        }
        return lighting
    }

    /// The day's path every 10 minutes while the sun's up, bigger on the
    /// hour, the sun now biggest, and a faint horizon ring every 5° to read
    /// azimuths against: a sun-path diagram on a dome over the anchor.
    private func sunPathDots(coordinate: GeoCoordinate, current: SolarPosition,
                             radius: Double) -> [MetalTileRenderer.SunPathDot] {
        let start = clock.startOfDay
        let key = SIMD3(start.timeIntervalSince1970, (coordinate.latitude * 100).rounded(),
                        (coordinate.longitude * 100).rounded())
        let path: [(date: Date, position: SolarPosition)]
        if let cached = pathCache, cached.key == key {
            path = cached.path
        } else {
            path = SolarPosition.dayPath(containing: clock.instant, timeZone: clock.timeZone,
                                         latitude: coordinate.latitude, longitude: coordinate.longitude)
            pathCache = (key, path)
        }
        func dot(_ direction: SIMD3<Double>, size: Float, colour: SIMD4<Float>) -> MetalTileRenderer.SunPathDot {
            MetalTileRenderer.SunPathDot(position: SIMD4(SIMD3<Float>(direction * radius), size), colour: colour)
        }
        var dots: [MetalTileRenderer.SunPathDot] = []
        for azimuth in stride(from: 0.0, to: 360, by: 5) {
            let north = azimuth == 0
            dots.append(dot(SolarPosition(azimuth: azimuth, elevation: 0, declination: 0, equationOfTime: 0).anchorFrame,
                            size: north ? 0.006 : 0.0025,
                            colour: north ? SIMD4(0.9, 0.2, 0.15, 1) : SIMD4(0.6, 0.6, 0.6, 1)))
        }
        for (index, sample) in path.enumerated() where sample.position.apparentElevation > -0.5 {
            let onTheHour = index % 6 == 0
            dots.append(dot(sample.position.anchorFrame, size: onTheHour ? 0.006 : 0.0035,
                            colour: onTheHour ? SIMD4(1, 0.8, 0.35, 1) : SIMD4(1, 0.55, 0.12, 1)))
        }
        if current.apparentElevation > -0.5 {
            dots.append(dot(current.anchorFrame, size: 0.018, colour: SIMD4(1, 0.97, 0.8, 1)))
        }
        return dots
    }

    // MARK: The place's time zone

    /// Times are the place's, so "8 am in December" means the same thing
    /// wherever the device is. Until the lookup answers (or if it fails, as
    /// it will offline), the longitude's hour stands in.
    private func updateTimeZone(for coordinate: GeoCoordinate) {
        if let last = timeZoneLookedUpAt, GeoMath.distance(from: last, to: coordinate) < timeZoneRefetchDistance {
            return
        }
        timeZoneLookedUpAt = coordinate
        setTimeZone(SunClock.approximateTimeZone(longitude: coordinate.longitude))
        timeZoneIsApproximate = true
        timeZoneLookup?.cancel()
        timeZoneLookup = Task { [weak self] in
            // UNVERIFIED: CLGeocoder is deprecated in the 26 SDKs in favour of
            // MapKit's MKReverseGeocodingRequest, but still available; this
            // only reads the placemark's time zone, nothing is drawn. Swap
            // for the MapKit request if the warning matters.
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let zone = try? await CLGeocoder().reverseGeocodeLocation(location).first?.timeZone
            guard let self, !Task.isCancelled, let zone else { return }
            self.setTimeZone(zone)
            self.timeZoneIsApproximate = false
        }
    }

    // MARK: Helpers

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func environment(_ name: String) -> Double? {
        ProcessInfo.processInfo.environment[name].flatMap(Double.init)
    }

    private static func offset(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = abs(seconds % 3600) / 60
        return (seconds < 0 ? "−" : "+") + "\(abs(hours))" + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }
}
