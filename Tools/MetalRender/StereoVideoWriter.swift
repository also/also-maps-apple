import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Serial, bounded recording: keep one stereo pair in memory and respect encoder backpressure.
final class StereoVideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let stereo: AVAssetWriterInputTaggedPixelBufferGroupAdaptor?
    private let packed: AVAssetWriterInputPixelBufferAdaptor?
    private let options: VideoOptions
    private let temporary: URL
    private let destination: URL
    private var finished = false

    init(options: VideoOptions, directory: URL) throws {
        self.options = options
        temporary = directory.appendingPathComponent("video.partial.mov")
        destination = directory.appendingPathComponent("video.mov")
        writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: min(150_000_000, max(2_000_000, options.width * options.height * options.fps / 2)),
            AVVideoExpectedSourceFrameRateKey: options.fps,
            AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
            AVVideoAllowFrameReorderingKey: false
        ]
        if options.format == .spatial {
            compression[kVTCompressionPropertyKey_MVHEVCVideoLayerIDs as String] = [0, 1]
            compression[kVTCompressionPropertyKey_MVHEVCViewIDs as String] = [0, 1]
            compression[kVTCompressionPropertyKey_MVHEVCLeftAndRightViewIDs as String] = [0, 1]
            compression[kVTCompressionPropertyKey_HasLeftStereoEyeView as String] = true
            compression[kVTCompressionPropertyKey_HasRightStereoEyeView as String] = true
            compression[kVTCompressionPropertyKey_ProjectionKind as String] = kCMFormatDescriptionProjectionKind_Rectilinear
            compression[kVTCompressionPropertyKey_StereoCameraBaseline as String] = UInt32((options.baseline * 1000).rounded())
            compression[kVTCompressionPropertyKey_HorizontalFieldOfView as String] = UInt32((options.horizontalFOV * 1000).rounded())
            // Convergence is already baked into the off-axis projections; no additional player shift.
            compression[kVTCompressionPropertyKey_HorizontalDisparityAdjustment as String] = Int32(0)
        }
        let width = options.width * (options.format == .sbs ? 2 : 1)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: options.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw RenderCLIError("Encoder cannot apply \(options.format.rawValue) settings; try --format sbs or a smaller size")
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: width,
                                         kCVPixelBufferHeightKey as String: options.height,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        if options.format == .spatial {
            stereo = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
            packed = nil
        } else {
            stereo = nil
            packed = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        }
        guard writer.canAdd(input) else { throw RenderCLIError("Cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw failure("Cannot start encoder") }
        writer.startSession(atSourceTime: .zero)
    }

    deinit {
        if !finished {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private func failure(_ message: String) -> RenderCLIError {
        RenderCLIError("\(message): \(writer.error?.localizedDescription ?? "encoder unavailable")")
    }

    private func pixelBuffer(left: Data, right: Data?, credits: [String]) throws -> CVPixelBuffer {
        let pool = stereo?.pixelBufferPool ?? packed?.pixelBufferPool
        guard let pool else { throw failure("No pixel buffer pool") }
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess, let buffer = result else {
            throw RenderCLIError("Could not allocate video pixel buffer")
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw RenderCLIError("Could not lock video pixel buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw RenderCLIError("No video buffer memory") }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for (eye, pixels) in [left, right].compactMap({ $0 }).enumerated() {
            pixels.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: UInt8.self)
                for y in 0..<options.height {
                    let target = base.advanced(by: y * row + eye * options.width * 4).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<options.width {
                        let offset = (y * options.width + x) * 4
                        target[x * 4] = source[offset + 2]
                        target[x * 4 + 1] = source[offset + 1]
                        target[x * 4 + 2] = source[offset]
                        target[x * 4 + 3] = 255
                    }
                }
            }
        }
        // Attribution is burned into each eye at identical screen coordinates.
        // Quartz's default bitmap transform places upright text in the bottom rows.
        if !credits.isEmpty {
            guard let context = CGContext(data: base, width: CVPixelBufferGetWidth(buffer), height: options.height,
                                          bitsPerComponent: 8, bytesPerRow: row,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw RenderCLIError("Cannot draw video attribution")
            }
            for eye in 0..<(right == nil ? 1 : 2) {
                try Self.attribution(credits, in: context, x: eye * options.width, width: options.width, height: options.height)
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    private static func attribution(_ credits: [String], in context: CGContext, x: Int, width: Int, height: Int) throws {
        let fontSize = max(10, min(22, Double(width) / 85))
        let text = NSAttributedString(string: credits.joined(separator: " · "), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ])
        let setter = CTFramesetterCreateWithAttributedString(text)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: CGFloat(width - 24), height: .greatestFiniteMagnitude), nil)
        let footer = ceil(size.height) + 16
        guard footer <= Double(height) / 3 else { throw RenderCLIError("Attribution needs a larger per-eye video size") }
        context.setFillColor(CGColor(gray: 0.04, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: width, height: Int(footer)))
        let path = CGPath(rect: CGRect(x: x + 12, y: 8, width: width - 24, height: Int(footer) - 16), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        guard CTFrameGetVisibleStringRange(frame).length == text.length else { throw RenderCLIError("Attribution was truncated") }
        CTFrameDraw(frame, context)
    }

    func append(left: Data, right: Data, credits: [String], frame: Int) throws {
        let deadline = Date().addingTimeInterval(60)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else { throw failure("Encoder stalled") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        let time = CMTime(value: Int64(frame), timescale: Int32(options.fps))
        let appended: Bool
        if let stereo {
            let a = try pixelBuffer(left: left, right: nil, credits: credits)
            let b = try pixelBuffer(left: right, right: nil, credits: credits)
            appended = stereo.appendTaggedBuffers([
                CMTaggedBuffer(tags: [.videoLayerID(0), .stereoView(.leftEye)], buffer: .pixelBuffer(a)),
                CMTaggedBuffer(tags: [.videoLayerID(1), .stereoView(.rightEye)], buffer: .pixelBuffer(b))
            ], withPresentationTime: time)
        } else {
            appended = try packed!.append(pixelBuffer(left: left, right: right, credits: credits), withPresentationTime: time)
        }
        guard appended else { throw failure("Could not append stereo frame \(frame)") }
    }

    func finish(frameCount: Int) throws {
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: Int32(options.fps)))
        input.markAsFinished()
        let completion = DispatchSemaphore(value: 0)
        writer.finishWriting { completion.signal() }
        guard completion.wait(timeout: .now() + 60) == .success, writer.status == .completed else {
            throw failure("Could not finish video")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        finished = true
    }

    static func preview(left: Data, right: Data, options: VideoOptions, credits: [String], to url: URL) throws {
        // Pack raw top-first Metal rows into a full-width SBS preview.
        let width = options.width * 2
        var rgba = Data(count: width * options.height * 4)
        rgba.withUnsafeMutableBytes { target in
            for (eye, pixels) in [left, right].enumerated() {
                pixels.withUnsafeBytes { source in
                    for y in 0..<options.height {
                        memcpy(target.baseAddress!.advanced(by: (y * width + eye * options.width) * 4),
                               source.baseAddress!.advanced(by: y * options.width * 4), options.width * 4)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: options.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let context = CGContext(data: nil, width: width, height: options.height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderCLIError("Cannot create stereo preview")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: options.height))
        if !credits.isEmpty {
            for eye in 0..<2 { try attribution(credits, in: context, x: eye * options.width, width: options.width, height: options.height) }
        }
        guard let result = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderCLIError("Cannot create preview PNG")
        }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderCLIError("Cannot write preview PNG") }
    }
}
