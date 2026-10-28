import Foundation

/// A fixed camera and what to stream for it. The camera is also the camera
/// level of detail is selected for. Pick one with MAPVOLUME_VIEW (`bay`, the
/// default, or `ferry`). Streaming can be overridden for quick experiments:
/// MAPVOLUME_RADIUS (area of interest half-width, metres),
/// MAPVOLUME_DETAIL and MAPVOLUME_OUTER_DETAIL (pixels of error on screen),
/// MAPVOLUME_LOADS and MAPVOLUME_UPLOADS (concurrency).
struct StaticView {
    var name: String
    var inputs: StreamingInputs
    var settings: StreamingSettings
    var viewportSize: CGSize
    var near: Float
    var far: Float
    var samplesGround = false

    /// The bridge selects detail as if the view were this many pixels tall
    /// (see `ViewState` in CNTileStreamer.mm), whatever the window is.
    private static let assumedViewportHeight = 2048.0

    /// A `StreamingSettings` detail value that means `pixels` of error in a
    /// window `windowHeight` points tall.
    static func detail(pixels: Double, windowHeight: Double) -> Double {
        pixels * assumedViewportHeight / windowHeight
    }

    /// The Ferry Building, from over the bay looking west at downtown,
    /// streaming 3 km around. Detail is the app's default, which assumes a
    /// 2048-pixel-tall view rather than this 900-point window.
    static let ferry: StaticView = {
        let focus = GeoCoordinate(latitude: 37.7955, longitude: -122.3937)
        return StaticView(name: "ferry",
                          inputs: StreamingInputs(anchor: StreamingAnchor(coordinate: focus),
                                                  lod: .orbit(heading: 3 * .pi / 2,
                                                              elevation: 35 * .pi / 180,
                                                              distance: 2500),
                                                  regionHeading: 3 * .pi / 2,
                                                  streamingRadius: 3000),
                          settings: .default,
                          viewportSize: CGSize(width: 900, height: 900),
                          near: 1, far: 100_000)
    }()

    /// Downtown San Francisco in the foreground, then the bay, San Pablo Bay,
    /// Napa and the hills behind, out to the horizon: the camera of a Google
    /// Earth Web link, for comparing how fast the same view fills in.
    /// Google's link is `@37.84621441,-122.39504907,-3.00480709a,9744.84d,35y,6.10h,84.99t,0r`:
    /// look-at point, its altitude, range, vertical field of view, heading
    /// and tilt from straight down. The streamed region is a square around
    /// the look-at point, wide enough to cover the horizon ahead.
    static let bay: StaticView = {
        let size = CGSize(width: 1200, height: 800)
        let target = GeoCoordinate(latitude: 37.84621441, longitude: -122.39504907)
        let heading = 6.10259167 * Double.pi / 180
        var lod = LODCamera.orbit(heading: heading,
                                  elevation: (90 - 84.98672149) * .pi / 180,
                                  distance: 9744.84327601)
        lod.fieldOfView = 35 * .pi / 180
        lod.aspect = size.width / size.height
        var settings = StreamingSettings.default
        // On-screen pixels of error, not the default's 2048-pixel view.
        settings.detail = detail(pixels: 16, windowHeight: size.height)
        settings.outerDetail = detail(pixels: 64, windowHeight: size.height)
        return StaticView(name: "bay",
                          // Google's altitude is above sea level; the water
                          // here is about 32.7 m below the ellipsoid.
                          inputs: StreamingInputs(anchor: StreamingAnchor(coordinate: target, height: -3 - 32.7),
                                                  lod: lod,
                                                  regionHeading: heading,
                                                  streamingRadius: 150_000),
                          settings: settings,
                          viewportSize: size,
                          near: 10, far: 400_000)
    }()

    /// The view named by MAPVOLUME_VIEW, with any streaming overrides.
    static func fromEnvironment(defaultView: StaticView = .bay,
                                viewportSize: CGSize? = nil) -> StaticView {
        let env = ProcessInfo.processInfo.environment
        var view: StaticView
        switch env["MAPVOLUME_VIEW"] {
        case "ferry": view = ferry
        case "bay": view = bay
        default: view = defaultView
        }
        if let viewportSize {
            view.viewportSize = viewportSize
            view.inputs.lod.aspect = viewportSize.width / viewportSize.height
        }
        func number(_ key: String) -> Double? { env[key].flatMap(Double.init) }
        if let radius = number("MAPVOLUME_RADIUS") { view.inputs.streamingRadius = radius }
        if let pixels = number("MAPVOLUME_DETAIL") {
            view.settings.detail = detail(pixels: pixels, windowHeight: view.viewportSize.height)
        }
        if let pixels = number("MAPVOLUME_OUTER_DETAIL") {
            view.settings.outerDetail = detail(pixels: pixels, windowHeight: view.viewportSize.height)
        }
        if let loads = number("MAPVOLUME_LOADS") { view.settings.simultaneousLoads = loads }
        if let uploads = number("MAPVOLUME_UPLOADS") { view.settings.uploadConcurrency = uploads }
        return view
    }
}

extension StaticView {
    static func place(_ place: Place, viewportSize: CGSize, settings: StreamingSettings) -> StaticView {
        let radius = max(place.radius, 50)
        let heading = place.heading * .pi / 180
        var lod = LODCamera.orbit(heading: heading, elevation: .pi / 4,
                                  distance: radius * 2.5)
        lod.aspect = viewportSize.width / viewportSize.height
        return StaticView(name: place.name,
                          inputs: StreamingInputs(anchor: StreamingAnchor(coordinate: place.coordinate),
                                                  lod: lod,
                                                  regionHeading: heading,
                                                  streamingRadius: radius),
                          settings: settings,
                          viewportSize: viewportSize,
                          near: 1, far: Float(max(100_000, radius * 20)),
                          samplesGround: true)
    }
}
