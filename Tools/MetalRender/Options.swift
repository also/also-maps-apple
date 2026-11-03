import Foundation

struct RenderCLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct RenderOptions: Codable {
    var google = false
    var width = 1280
    var height = 720
    var frames = 30
    var timeout = 90.0
    var latitude = 40.7549
    var longitude = -73.984
    /// Metres above the WGS84 ellipsoid, not terrain-relative height.
    var altitude = 600.0
    var heading = 0.0
    var pitch = -12.0
    var radius = 1500.0
    var detail = 32.0
    var outerDetail = 128.0
    var output = "build/headless-render"

    static func parse(_ arguments: [String]) throws -> RenderOptions {
        var options = RenderOptions()
        var index = 0
        func number(_ text: String) throws -> Double {
            guard let value = Double(text), value.isFinite else { throw RenderCLIError("Expected a finite number") }
            return value
        }
        func integer(_ text: String) throws -> Int {
            guard let value = Int(text) else { throw RenderCLIError("Expected an integer") }
            return value
        }
        while index < arguments.count {
            let key = arguments[index]
            index += 1
            if key == "--google" { options.google = true; continue }
            guard index < arguments.count else { throw RenderCLIError("Missing value for \(key)") }
            let value = arguments[index]
            index += 1
            switch key {
            case "--width": options.width = try integer(value)
            case "--height": options.height = try integer(value)
            case "--frames": options.frames = try integer(value)
            case "--timeout": options.timeout = try number(value)
            case "--latitude": options.latitude = try number(value)
            case "--longitude": options.longitude = try number(value)
            case "--altitude": options.altitude = try number(value)
            case "--heading": options.heading = try number(value)
            case "--pitch": options.pitch = try number(value)
            case "--radius": options.radius = try number(value)
            case "--detail": options.detail = try number(value)
            case "--outer-detail": options.outerDetail = try number(value)
            case "--output": options.output = value
            default: throw RenderCLIError("Unknown option \(key)")
            }
        }
        guard (16...4096).contains(options.width), (16...4096).contains(options.height),
              (1...1000).contains(options.frames), (1...300).contains(options.timeout),
              (-90...90).contains(options.latitude), (-180...180).contains(options.longitude),
              (1...1_000_000).contains(options.altitude), (-90...89).contains(options.pitch),
              (-36_000...36_000).contains(options.heading),
              (1...20_000).contains(options.radius), (0.1...1024).contains(options.detail),
              (0.1...1024).contains(options.outerDetail), !options.output.isEmpty else {
            throw RenderCLIError("Options out of range; see --help")
        }
        return options
    }

    static let help = """
    Usage: also-maps-render [--google] [options]
    Renders offscreen with the app's Metal shader; no window or UI automation.
    Default: a deterministic synthetic culling regression, with no network/key.
    --google                 Stream Google tiles, then freeze one snapshot for A/B
    --latitude N --longitude N  Camera position (default Midtown Manhattan)
    --altitude N             Camera height above ellipsoid, metres (default 600)
    --heading N --pitch N     Degrees; heading clockwise from north, pitch up-positive
    --radius N               Streaming half-width, metres (default 1500)
    --detail N --outer-detail N  Cesium SSE thresholds (default 32 / 128)
    --width N --height N      Offscreen pixels (default 1280 x 720; 16...4096)
    --frames N               Measured frames per mode (default 30; 1...1000)
    --timeout N              Tile-load timeout, seconds (default 90; 1...300)
    --output PATH            PNGs and JSON report (default build/headless-render)
    Google key: GOOGLE_MAPS_API_KEY environment, then Debug binary's embedded config.
    GPU failures, incomplete loads, or culling image differences exit nonzero.
    """
}
