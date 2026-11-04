import Foundation
import simd

private final class VideoTileSession {
    let streamer: CNTileStreamer
    private let options: VideoOptions

    init(options: VideoOptions, renderer: MetalTileRenderer) throws {
        self.options = options
        let environment = ProcessInfo.processInfo.environment["GOOGLE_MAPS_API_KEY"] ?? ""
        let key = environment.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String ?? "") : environment
        guard !key.isEmpty else { throw RenderCLIError("Google mode needs GOOGLE_MAPS_API_KEY or a Debug build with Secrets.xcconfig") }
        var url = URLComponents(string: "https://tile.googleapis.com/v1/3dtiles/root.json")!
        url.queryItems = [URLQueryItem(name: "key", value: key)]
        streamer = CNTileStreamer(tilesetURL: url.url!.absoluteString)
        streamer.tileLoadHandler = renderer.handler
        // Equal SSE inside/outside the central view also refines both shifted eye frusta.
        streamer.maximumScreenSpaceError = options.detail
        streamer.culledScreenSpaceError = options.detail
        streamer.maximumSimultaneousTileLoads = 16
        streamer.maximumCachedBytes = 512 * 1024 * 1024
        streamer.forbidHoles = true
    }

    func scene(at camera: CameraPose) throws -> Scene {
        let aspect = Double(options.width) / Double(options.height)
        let verticalFOV = 2 * atan(tan(options.horizontalFOV * .pi / 360) / aspect)
        let inputs = ScreenView.streamingInputs(camera: camera, groundHeight: 0, fieldOfView: verticalFOV, aspect: aspect)
        streamer.anchorLatitude = inputs.anchor.coordinate.latitude
        streamer.anchorLongitude = inputs.anchor.coordinate.longitude
        streamer.anchorHeight = inputs.anchor.height
        streamer.streamingRadius = options.radius
        streamer.regionHeading = inputs.regionHeading
        streamer.viewPosition = inputs.lod.position
        streamer.viewDirection = inputs.lod.direction
        streamer.viewUp = inputs.lod.up
        streamer.viewFieldOfView = inputs.lod.fieldOfView
        streamer.viewAspect = inputs.lod.aspect
        let deadline = Date().addingTimeInterval(options.timeout)
        var stableSince: Date?
        var ids: [UInt64] = []
        var snapshot: CNFrame?
        while Date() < deadline {
            let frame = autoreleasepool { streamer.update(withDeltaTime: 1 / Float(options.fps)) }
            let status = streamer.takeKeyFailureStatus()
            guard status == 0 else { throw RenderCLIError("Tile service returned HTTP \(status)") }
            let current = frame.tilesToRender.map(\.identifier)
            if frame.loadProgress >= 100, !current.isEmpty, current == ids {
                stableSince = stableSince ?? Date()
                if Date().timeIntervalSince(stableSince!) >= options.settle { snapshot = frame; break }
            } else { stableSince = nil }
            ids = current
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let snapshot else { throw RenderCLIError("Tiles did not settle within --timeout; recording stopped") }
        let draws = snapshot.tileTransforms.withUnsafeBytes { bytes in
            let placements = bytes.bindMemory(to: simd_float4x4.self)
            return snapshot.tilesToRender.enumerated().compactMap { index, mesh -> MetalTileRenderer.Draw? in
                guard let tile = mesh.renderObject as? MetalTileRenderer.Tile else { return nil }
                return .init(tile: tile, placement: placements[index])
            }
        }
        guard !draws.isEmpty else { throw RenderCLIError("Loaded tiles have no Metal resources") }
        let placement = ScreenView.georeference(camera: camera).placement(of: inputs.anchor)
        var root = simd_float4x4(simd_quatf(vector: SIMD4<Float>(placement.rotation.vector)))
        for column in 0..<3 { root[column] *= Float(placement.scale) }
        root.columns.3 = SIMD4(SIMD3<Float>(placement.translation), 1)
        let orientation = simd_float4x4(simd_quatf(vector: SIMD4<Float>(ScreenView.cameraOrientation(camera: camera).vector)))
        let fetch = streamer.fetchStats()
        return Scene(draws: draws, viewProjection: orientation.inverse, root: root,
                     credits: Array(Set(["Google Maps"] + snapshot.credits.map(\.text))).sorted(),
                     fetch: ["cacheHits": fetch.cacheHits, "revalidated": fetch.revalidated,
                             "networkLoads": fetch.networkLoads, "networkBytes": fetch.networkBytes])
    }
}

private struct VideoFrameReport: Codable {
    let index: Int
    let presentationSeconds: Double
    let pose: CameraPose
    let tileCount: Int
    let left: MetalDrawStatistics
    let right: MetalDrawStatistics
    let credits: [String]
}

private struct VideoReport: Codable {
    let options: VideoOptions
    let device: String
    let frames: Int
    let encodedDuration: Double
    let routeDuration: Double
    let worldMetresBetweenEyes: Double
    let worldMetresToConvergence: Double
    let physicalMetresPerWorldMetre: Double
    let fetch: [String: UInt64]
    let samples: [VideoFrameReport]
}

enum StereoVideoCapture {
    static func run(_ options: VideoOptions) throws {
        let journey = try VideoJourney(options)
        let directory = URL(fileURLWithPath: options.output, isDirectory: true)
        // Fail before loading tiles or starting an encoder when an output already exists.
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw RenderCLIError("Output directory already exists; choose a new --output")
        }
        var renderOptions = RenderOptions()
        renderOptions.width = options.width; renderOptions.height = options.height
        let offscreen = try OffscreenRenderer(options: renderOptions)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writer = try StereoVideoWriter(options: options, directory: directory)
        let session = try options.google ? VideoTileSession(options: options, renderer: offscreen.renderer) : nil
        let synthetic = try options.google ? nil : MetalRenderCLI.syntheticScene(renderer: offscreen.renderer,
                                                                               aspect: Float(options.width) / Float(options.height))
        let firstPose = journey.pose(frame: 0)
        let firstReference = ScreenView.georeference(camera: firstPose)
        let firstOrientation = simd_float4x4(simd_quatf(vector: SIMD4<Float>(ScreenView.cameraOrientation(camera: firstPose).vector)))
        var samples: [VideoFrameReport] = []
        var fetch: [String: UInt64] = [:]
        var totalDraws = 0
        for index in 0..<journey.frameCount {
            try autoreleasepool {
                let pose = journey.pose(frame: index)
                var scene: Scene
                if let session { scene = try session.scene(at: pose) }
                else {
                    scene = synthetic!
                    // Small geographic test movement in the initial camera's local frame.
                    let offset = firstReference.rotation.act(pose.position - firstPose.position)
                    var cameraTransform = simd_float4x4(simd_quatf(vector: SIMD4<Float>(ScreenView.cameraOrientation(camera: pose).vector)))
                    cameraTransform.columns.3 = SIMD4(SIMD3<Float>(offset), 1)
                    scene.root = firstOrientation
                    scene.viewProjection = cameraTransform.inverse
                }
                fetch = scene.fetch
                let (near, far) = options.google ? ScreenView.clipping(altitude: pose.height) : (0.1, 100.0)
                func eye(_ sign: Float) throws -> (MetalDrawStatistics, Data) {
                    var eyeScene = scene
                    eyeScene.viewProjection = StereoCamera.projection(eyeX: sign * Float(options.worldBaseline / 2),
                        convergence: Float(options.convergenceDistance), horizontalFOV: Float(options.horizontalFOV * .pi / 180),
                        aspect: Float(options.width) / Float(options.height), near: Float(near), far: Float(far)) * scene.viewProjection
                    let result = try offscreen.frame(eyeScene, culling: true, readback: true, requireDraws: false)
                    return (result.statistics, result.pixels)
                }
                // Both eyes share exactly the same tile snapshot; selection cannot change between them.
                let left = try eye(-1), right = try eye(1)
                totalDraws += left.0.drawCalls + right.0.drawCalls
                try writer.append(left: left.1, right: right.1, credits: scene.credits, frame: index)
                if index == 0 || index == journey.frameCount - 1 {
                    try StereoVideoWriter.preview(left: left.1, right: right.1, options: options, credits: scene.credits,
                                                  to: directory.appendingPathComponent(index == 0 ? "first-sbs.png" : "last-sbs.png"))
                }
                samples.append(VideoFrameReport(index: index, presentationSeconds: Double(index) / Double(options.fps),
                    pose: pose, tileCount: scene.draws.count, left: left.0, right: right.0, credits: scene.credits))
                if index == 0 || (index + 1).isMultiple(of: options.fps) || index == journey.frameCount - 1 {
                    print("Stereo frame \(index + 1)/\(journey.frameCount); \(scene.draws.count) tiles")
                }
            }
        }
        guard totalDraws > 0 else { throw RenderCLIError("No geometry appeared in the recording") }
        try writer.finish(frameCount: journey.frameCount)
        let report = VideoReport(options: options, device: offscreen.renderer.device.name, frames: journey.frameCount,
            encodedDuration: Double(journey.frameCount) / Double(options.fps), routeDuration: journey.duration,
            worldMetresBetweenEyes: options.worldBaseline, worldMetresToConvergence: options.convergenceDistance,
            physicalMetresPerWorldMetre: options.scale, fetch: fetch, samples: samples)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
        print("Recorded \(options.format.rawValue): \(directory.appendingPathComponent("video.mov").path)")
    }
}
