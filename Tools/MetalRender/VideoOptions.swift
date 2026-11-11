import Foundation
import simd

struct VideoOptions: Codable {
    enum Format: String, Codable { case spatial, sbs }
    var google = false
    var format = Format.spatial
    var width = 1280
    var height = 720
    var fps = 30
    var duration: Double?
    var start = 0.0
    var track: String?
    var from: CameraPose?
    var to: CameraPose?
    var baseline = 64.0  // Physical camera separation, mm, also written to spatial metadata.
    var worldScale: Double?  // Physical metres per geographic metre.
    var convergence: Double? // Geographic metres; parallel optical axes, shifted frusta.
    var horizontalFOV = 75.0
    var radius = 2500.0
    var detail = 16.0
    var timeout = 90.0
    var settle = 0.1
    var output = "build/stereo-video"

    var scale: Double { worldScale ?? (google ? 0.01 : 1) }
    var convergenceDistance: Double { convergence ?? (google ? 1000 : 6) }
    var worldBaseline: Double { baseline / 1000 / scale }
    var initialPose: CameraPose {
        from ?? (google
            ? CameraPose(latitude: 40.7549, longitude: -73.984, height: 600, heading: 0, pitch: -12 * .pi / 180)
            : CameraPose(latitude: 0, longitude: 0, height: 10, heading: 0, pitch: 0))
    }
    var finalPose: CameraPose {
        if let to { return to }
        var pose = initialPose
        if google { pose.latitude += 0.001 } else { pose.longitude += 0.00001 }
        return pose
    }

    static func valid(_ pose: CameraPose) -> Bool {
        [pose.latitude, pose.longitude, pose.height, pose.heading, pose.pitch].allSatisfy(\.isFinite)
            && (-90...90).contains(pose.latitude) && (-180...180).contains(pose.longitude)
            && (-500...1_000_000).contains(pose.height) && (-.pi / 2 ... .pi / 2).contains(pose.pitch)
            && abs(pose.heading) <= 200 * .pi
    }

    static func parse(_ arguments: [String]) throws -> Self {
        var options = Self()
        var index = 0
        func number(_ value: String) throws -> Double {
            guard let n = Double(value), n.isFinite else { throw RenderCLIError("Expected a finite number") }
            return n
        }
        func integer(_ value: String) throws -> Int {
            guard let n = Int(value) else { throw RenderCLIError("Expected an integer") }
            return n
        }
        func pose(_ value: String) throws -> CameraPose {
            let fields = value.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 5 else { throw RenderCLIError("Pose needs latitude,longitude,height,heading,pitch") }
            let n = try fields.map { try number(String($0)) }
            let pose = CameraPose(latitude: n[0], longitude: n[1], height: n[2], heading: n[3] * .pi / 180,
                                  pitch: n[4] * .pi / 180)
            guard valid(pose) else { throw RenderCLIError("Camera pose out of range") }
            return pose
        }
        while index < arguments.count {
            let key = arguments[index]; index += 1
            if key == "--google" { options.google = true; continue }
            guard index < arguments.count else { throw RenderCLIError("Missing value for \(key)") }
            let value = arguments[index]; index += 1
            switch key {
            case "--format":
                guard let format = Format(rawValue: value) else { throw RenderCLIError("Format must be spatial or sbs") }
                options.format = format
            case "--width": options.width = try integer(value)
            case "--height": options.height = try integer(value)
            case "--fps": options.fps = try integer(value)
            case "--duration": options.duration = try number(value)
            case "--start": options.start = try number(value)
            case "--track": options.track = value
            case "--from": options.from = try pose(value)
            case "--to": options.to = try pose(value)
            case "--baseline": options.baseline = try number(value)
            case "--world-scale": options.worldScale = try number(value)
            case "--convergence": options.convergence = try number(value)
            case "--fov": options.horizontalFOV = try number(value)
            case "--radius": options.radius = try number(value)
            case "--detail": options.detail = try number(value)
            case "--timeout": options.timeout = try number(value)
            case "--settle": options.settle = try number(value)
            case "--output": options.output = value
            default: throw RenderCLIError("Unknown video option \(key)")
            }
        }
        guard (64...4096).contains(options.width), options.width.isMultiple(of: 2),
              (64...4096).contains(options.height), options.height.isMultiple(of: 2),
              (1...60).contains(options.fps), (0.05...600).contains(options.duration ?? 3),
              (0...86_400).contains(options.start), (1...100).contains(options.baseline),
              (0.0001...100).contains(options.scale), (0.1...1_000_000).contains(options.convergenceDistance),
              options.worldBaseline / options.convergenceDistance < 0.25,
              (20...120).contains(options.horizontalFOV), (1...20_000).contains(options.radius),
              (0.1...1024).contains(options.detail), (1...300).contains(options.timeout),
              (0.05...2).contains(options.settle), !options.output.isEmpty,
              options.track == nil || (options.google && options.from == nil && options.to == nil && !options.track!.isEmpty),
              options.track != nil || options.start == 0,
              valid(options.initialPose), valid(options.finalPose) else {
            throw RenderCLIError("Video options out of range or conflicting; see video --help")
        }
        return options
    }

    static let help = """
    Usage: also-maps-render video [--google] [options]
    Offline stereo recording, no window. Default: a 3-second synthetic test.
    --google                  Use Google terrain (same key rules as the benchmark)
    --from LAT,LON,M,H,P       A pose; metres above ellipsoid, heading/pitch in degrees
    --to LAT,LON,M,H,P         B pose; smooth eased A-to-B move (default 111 m north)
    --track PATH.csv          Instead follow an app camera track (Google mode)
    --start N --duration N    Track offset and crop in seconds; default entire track
    --duration N              A-to-B length (default 3 s; up to 600 s)
    --format spatial|sbs      MV-HEVC spatial MOV (default), or full-width SBS HEVC MOV
    --width N --height N      Pixels PER EYE, even 64...4096 (default 1280 x 720)
    --fps N                   Fixed output rate, 1...60 (default 30)
    --baseline N              Physical eye spacing in mm, 1...100 (default 64)
    --world-scale N           Physical metres/geographic metre (Google .01; synthetic 1)
    --convergence N           Zero-disparity distance in geographic metres (Google 1000)
    --fov N                   Horizontal per-eye FOV, degrees 20...120 (default 75)
    --radius N --detail N     Streaming half-width metres / SSE (default 2500 / 16)
    --timeout N --settle N    Per-pose load timeout / stable seconds (default 90 / .1)
    --output DIRECTORY        New output directory (default build/stereo-video)
    Waits for each pose to finish loading; elapsed loading time is absent from video.
    Writes video.mov, first/last SBS PNGs and capture.json. Refuses existing output.
    Spatial is rectilinear stereo, not 180/360-degree Apple Immersive Video.
    """
}

struct VideoJourney {
    let options: VideoOptions
    let playback: TrackPlayback?
    let duration: Double
    let frameCount: Int

    init(_ options: VideoOptions) throws {
        self.options = options
        if let path = options.track {
            let url = URL(fileURLWithPath: path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10_000_000 else { throw RenderCLIError("Track exceeds 10 MB") }
            let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
            guard lines.first == Substring(CameraTrack.header) else { throw RenderCLIError("Unrecognized camera track header") }
            var samples: [CameraTrack.Sample] = []
            for line in lines.dropFirst() {
                guard let sample = CameraTrack.sample(fromLine: line), VideoOptions.valid(sample.pose), sample.segment >= 0,
                      samples.last.map({ sample.time > $0.time && sample.segment >= $0.segment }) ?? true else {
                    throw RenderCLIError("Track contains an invalid or out-of-order sample")
                }
                samples.append(sample)
            }
            guard let playback = TrackPlayback(samples: samples), options.start < playback.duration else {
                throw RenderCLIError("Track has no motion interval at --start")
            }
            self.playback = playback
            duration = options.duration ?? (playback.duration - options.start)
            guard (0.05...600).contains(duration), options.start + duration <= playback.duration + 0.000001 else {
                throw RenderCLIError("Requested interval extends beyond the track or exceeds 600 seconds; use --duration to crop")
            }
        } else {
            playback = nil
            duration = options.duration ?? 3
        }
        frameCount = Int(ceil(duration * Double(options.fps)))
        guard frameCount >= 2 else { throw RenderCLIError("Recording needs at least two frames; increase --duration or --fps") }
    }

    func pose(frame: Int) -> CameraPose {
        // Include both endpoints. Presentation timestamps remain exactly i/fps.
        let fraction = Double(frame) / Double(frameCount - 1)
        if let playback { return playback.pose(at: options.start + fraction * duration) }
        return TrackPlayback.interpolate(options.initialPose, options.finalPose, fraction * fraction * (3 - 2 * fraction))
    }
}

enum StereoCamera {
    /// Parallel, rectified cameras with matching off-axis frusta. No toe-in or vertical disparity.
    static func projection(eyeX: Float, convergence: Float, horizontalFOV: Float,
                           aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let x = tan(horizontalFOV / 2), y = x / aspect
        let shift = eyeX / convergence
        var view = matrix_identity_float4x4
        view.columns.3.x = -eyeX
        return MetalProjection.perspective(tangents: [x + shift, x - shift, y, y], near: near, far: far) * view
    }
}
