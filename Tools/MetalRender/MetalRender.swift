import Foundation
import Metal
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import simd

private struct Scene {
    let draws: [MetalTileRenderer.Draw]
    let viewProjection: simd_float4x4
    let root: simd_float4x4
    var credits: [String] = []
    var fetch: [String: UInt64] = [:]
}

private struct Timing: Codable {
    let cpuEncodeMS: Double
    let gpuMS: Double?
}

private struct ModeReport: Codable {
    let statistics: MetalDrawStatistics
    let samples: [Timing]
    let cpuEncodeMedianMS: Double
    let cpuEncodeP95MS: Double
    let gpuMedianMS: Double?
    let gpuP95MS: Double?

    init(statistics: MetalDrawStatistics, samples: [Timing]) {
        self.statistics = statistics
        self.samples = samples
        func percentile(_ values: [Double], _ fraction: Double) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        cpuEncodeMedianMS = percentile(samples.map(\.cpuEncodeMS), 0.5)!
        cpuEncodeP95MS = percentile(samples.map(\.cpuEncodeMS), 0.95)!
        gpuMedianMS = percentile(samples.compactMap(\.gpuMS), 0.5)
        gpuP95MS = percentile(samples.compactMap(\.gpuMS), 0.95)
    }
}

private struct Report: Codable {
    let device: String
    let options: RenderOptions
    let identicalPixels: Bool
    let differingPixels: Int
    let cullingOff: ModeReport
    let cullingOn: ModeReport
    let fetch: [String: UInt64]
    let credits: [String]
}

/// Serial offscreen passes intentionally isolate submission and GPU execution
/// from a window, display pacing, tile loading, and compositor work.
private final class OffscreenRenderer {
    let renderer: MetalTileRenderer
    let colour: MTLTexture
    private let depth: MTLTexture
    private let queue: MTLCommandQueue

    init(options: RenderOptions) throws {
        let renderer = try MetalTileRenderer()
        self.renderer = renderer
        guard let queue = renderer.device.makeCommandQueue() else { throw RenderCLIError("No command queue") }
        self.queue = queue
        func target(_ format: MTLPixelFormat, _ storage: MTLStorageMode) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: options.width,
                                                                     height: options.height, mipmapped: false)
            descriptor.storageMode = storage
            descriptor.usage = .renderTarget
            return renderer.device.makeTexture(descriptor: descriptor)
        }
        guard let colour = target(.rgba8Unorm_srgb, .shared), let depth = target(.depth32Float, .private) else {
            throw RenderCLIError("Could not allocate offscreen targets")
        }
        self.colour = colour
        self.depth = depth
    }

    func frame(_ scene: Scene, culling: Bool, readback: Bool = false) throws
        -> (statistics: MetalDrawStatistics, timing: Timing, pixels: Data) {
        guard let commands = queue.makeCommandBuffer() else { throw RenderCLIError("No command buffer") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MetalTileRenderer.skyColour
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 0
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderCLIError("No render encoder")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let statistics = renderer.encode(encoder, colour: colour.pixelFormat, depth: depth.pixelFormat,
                                         viewProjection: scene.viewProjection, root: scene.root,
                                         draws: scene.draws, cullingEnabled: culling)
        let encodeMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else {
            throw RenderCLIError("Metal command failed: \(commands.error?.localizedDescription ?? "unknown error")")
        }
        guard statistics.drawCalls > 0 else { throw RenderCLIError("No draws were encoded") }
        let gpuMS = commands.gpuEndTime > commands.gpuStartTime && commands.gpuStartTime > 0
            ? (commands.gpuEndTime - commands.gpuStartTime) * 1000 : nil
        var pixels = Data()
        if readback {
            pixels = Data(count: colour.width * colour.height * 4)
            pixels.withUnsafeMutableBytes {
                colour.getBytes($0.baseAddress!, bytesPerRow: colour.width * 4,
                                from: MTLRegionMake2D(0, 0, colour.width, colour.height), mipmapLevel: 0)
            }
        }
        return (statistics, Timing(cpuEncodeMS: encodeMS, gpuMS: gpuMS), pixels)
    }
}

@main
private enum MetalRenderCLI {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") { print(RenderOptions.help); return }
        do { try run(RenderOptions.parse(arguments)) }
        catch {
            FileHandle.standardError.write(Data("also-maps-render: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ options: RenderOptions) throws {
        let offscreen = try OffscreenRenderer(options: options)
        let scene = try options.google ? googleScene(options, renderer: offscreen.renderer)
            : syntheticScene(renderer: offscreen.renderer, aspect: Float(options.width) / Float(options.height))
        // Warm both code paths and pipeline creation before taking samples.
        for _ in 0..<5 {
            _ = try offscreen.frame(scene, culling: false)
            _ = try offscreen.frame(scene, culling: true)
        }
        let reference = try offscreen.frame(scene, culling: false, readback: true)
        let culled = try offscreen.frame(scene, culling: true, readback: true)
        var differingPixels = 0
        func srgbByte(_ linear: Double) -> Int {
            let value = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
            return Int((value * 255).rounded())
        }
        let sky = MetalTileRenderer.skyColour
        let clearPixel = [srgbByte(sky.red), srgbByte(sky.green), srgbByte(sky.blue), 255]
        var containsGeometry = false
        for pixel in stride(from: 0, to: reference.pixels.count, by: 4) {
            if reference.pixels[pixel..<(pixel + 4)] != culled.pixels[pixel..<(pixel + 4)] { differingPixels += 1 }
            if !containsGeometry {
                containsGeometry = (0..<4).contains { abs(Int(reference.pixels[pixel + $0]) - clearPixel[$0]) > 1 }
            }
        }
        guard containsGeometry else { throw RenderCLIError("Output contains only the clear colour") }
        if !options.google {
            guard reference.statistics.drawCalls == 5, culled.statistics.drawCalls == 2 else {
                throw RenderCLIError("Synthetic tile/primitive culling regression")
            }
        }
        var offSamples: [Timing] = [], onSamples: [Timing] = []
        for index in 0..<options.frames {
            // Alternate order to reduce systematic order/warmth bias. Both
            // paths see exactly the same immutable GPU resources/transforms.
            for culling in index.isMultiple(of: 2) ? [false, true] : [true, false] {
                let sample = try autoreleasepool { try offscreen.frame(scene, culling: culling).timing }
                if culling { onSamples.append(sample) } else { offSamples.append(sample) }
            }
        }
        let report = Report(device: offscreen.renderer.device.name, options: options,
                            identicalPixels: differingPixels == 0, differingPixels: differingPixels,
                            cullingOff: ModeReport(statistics: reference.statistics, samples: offSamples),
                            cullingOn: ModeReport(statistics: culled.statistics, samples: onSamples),
                            fetch: scene.fetch, credits: scene.credits)
        let directory = URL(fileURLWithPath: options.output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png(reference.pixels, options: options, credits: scene.credits, to: directory.appendingPathComponent("culling-off.png"))
        try png(culled.pixels, options: options, credits: scene.credits, to: directory.appendingPathComponent("culling-on.png"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        print("\(report.device): off \(reference.statistics.summary); on \(culled.statistics.summary)")
        print("Differing pixels: \(differingPixels). Report: \(directory.appendingPathComponent("report.json").path)")
        guard differingPixels == 0 else { throw RenderCLIError("Culling changed the rendered image") }
    }

    private static func syntheticScene(renderer: MetalTileRenderer, aspect: Float) throws -> Scene {
        func part(x: Float, z: Float, colour: SIMD4<Float>) throws -> MetalTileRenderer.Tile.Part {
            let positions: [SIMD4<Float>] = [[x - 1, -1, z, 0], [x + 1, -1, z, 0], [x, 1, z, 0]]
            let indices: [UInt32] = [0, 1, 2]
            let data = positions.withUnsafeBytes { Data($0) }
            guard let vertices = data.withUnsafeBytes({ renderer.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
                  let elements = indices.withUnsafeBytes({ renderer.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }) else {
                throw RenderCLIError("Could not allocate synthetic geometry")
            }
            return .init(bounds: MetalBounds(positions: data), positions: vertices, texcoords: nil, normals: nil,
                         indices: elements, indexCount: 3, texture: nil, sampler: nil, baseColor: colour)
        }
        let red = try part(x: -1, z: -6, colour: [0.9, 0.15, 0.05, 1])
        let blue = try part(x: 1, z: -5, colour: [0.05, 0.2, 0.9, 1])
        let behind = try part(x: 0, z: 5, colour: [0, 1, 0, 1])
        var outside = matrix_identity_float4x4
        outside.columns.3.x = 100
        return Scene(draws: [
            .init(tile: .init(parts: [red]), placement: matrix_identity_float4x4),
            .init(tile: .init(parts: [behind]), placement: matrix_identity_float4x4),
            .init(tile: .init(parts: [red]), placement: outside),
            .init(tile: .init(parts: [blue, behind]), placement: matrix_identity_float4x4)
        ], viewProjection: MetalProjection.perspective(tangents: [aspect, aspect, 1, 1], near: 0.1, far: 100),
                     root: matrix_identity_float4x4)
    }

    private static func googleScene(_ options: RenderOptions, renderer: MetalTileRenderer) throws -> Scene {
        let environmentKey = ProcessInfo.processInfo.environment["GOOGLE_MAPS_API_KEY"] ?? ""
        let key = environmentKey.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String ?? "") : environmentKey
        guard !key.isEmpty else { throw RenderCLIError("Google mode needs GOOGLE_MAPS_API_KEY or a Debug build with Secrets.xcconfig") }
        var url = URLComponents(string: "https://tile.googleapis.com/v1/3dtiles/root.json")!
        url.queryItems = [URLQueryItem(name: "key", value: key)]
        let streamer = CNTileStreamer(tilesetURL: url.url!.absoluteString)
        streamer.tileLoadHandler = renderer.handler
        let camera = CameraPose(latitude: options.latitude, longitude: options.longitude, height: options.altitude,
                                heading: options.heading * .pi / 180, pitch: options.pitch * .pi / 180)
        let aspect = Double(options.width) / Double(options.height), fieldOfView = Double.pi / 4
        let inputs = ScreenView.streamingInputs(camera: camera, groundHeight: 0, fieldOfView: fieldOfView, aspect: aspect)
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
        streamer.maximumScreenSpaceError = options.detail
        streamer.culledScreenSpaceError = options.outerDetail
        streamer.maximumSimultaneousTileLoads = 16
        streamer.maximumCachedBytes = 512 * 1024 * 1024
        streamer.forbidHoles = true
        let deadline = Date().addingTimeInterval(options.timeout)
        var settledSince: Date?
        var identifiers: [UInt64] = []
        var snapshot: CNFrame?
        while Date() < deadline {
            let frame = autoreleasepool { streamer.update(withDeltaTime: 1 / 60) }
            let status = streamer.takeKeyFailureStatus()
            guard status == 0 else { throw RenderCLIError("Tile service returned HTTP \(status)") }
            let current = frame.tilesToRender.map(\.identifier)
            if frame.loadProgress >= 100, !current.isEmpty, current == identifiers {
                settledSince = settledSince ?? Date()
                if Date().timeIntervalSince(settledSince!) >= 0.5 { snapshot = frame; break }
            } else { settledSince = nil }
            identifiers = current
            RunLoop.current.run(until: Date().addingTimeInterval(1 / 60))
        }
        guard let snapshot else { throw RenderCLIError("Tile load did not settle before timeout; no benchmark produced") }
        let draws = snapshot.tileTransforms.withUnsafeBytes { bytes in
            let placements = bytes.bindMemory(to: simd_float4x4.self)
            return snapshot.tilesToRender.enumerated().compactMap { index, mesh -> MetalTileRenderer.Draw? in
                guard let resources = mesh.renderObject as? MetalTileRenderer.Tile else { return nil }
                return .init(tile: resources, placement: placements[index])
            }
        }
        let placement = ScreenView.georeference(camera: camera).placement(of: inputs.anchor)
        var root = simd_float4x4(simd_quatf(vector: SIMD4<Float>(placement.rotation.vector)))
        for column in 0..<3 { root[column] *= Float(placement.scale) }
        root.columns.3 = SIMD4(SIMD3<Float>(placement.translation), 1)
        let orientation = simd_float4x4(simd_quatf(vector: SIMD4<Float>(ScreenView.cameraOrientation(camera: camera).vector)))
        let (near, far) = ScreenView.clipping(altitude: camera.height)
        let tangent = Float(tan(fieldOfView / 2))
        let projection = MetalProjection.perspective(tangents: [tangent * Float(aspect), tangent * Float(aspect), tangent, tangent],
                                                     near: Float(near), far: Float(far))
        let fetch = streamer.fetchStats()
        return Scene(draws: draws, viewProjection: projection * orientation.inverse, root: root,
                     credits: ["Google Maps"] + snapshot.credits.map(\.text),
                     fetch: ["cacheHits": fetch.cacheHits, "revalidated": fetch.revalidated,
                             "networkLoads": fetch.networkLoads, "networkBytes": fetch.networkBytes])
    }

    private static func png(_ pixels: Data, options: RenderOptions, credits: [String], to url: URL) throws {
        // Include attribution in Google captures as well as the JSON report.
        let footer = credits.isEmpty ? 0 : 64
        guard let context = CGContext(data: nil, width: options.width, height: options.height + footer,
                                      bitsPerComponent: 8, bytesPerRow: options.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: options.width, height: options.height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: options.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RenderCLIError("Could not construct image")
        }
        context.draw(image, in: CGRect(x: 0, y: footer, width: options.width, height: options.height))
        if footer > 0 {
            context.setFillColor(CGColor(gray: 0.08, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: options.width, height: footer))
            let text = NSAttributedString(string: credits.joined(separator: " · "), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ])
            let setter = CTFramesetterCreateWithAttributedString(text)
            let path = CGPath(rect: CGRect(x: 8, y: 6, width: options.width - 16, height: footer - 12), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        }
        guard let result = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderCLIError("Could not create PNG destination")
        }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderCLIError("Could not write PNG") }
    }
}
