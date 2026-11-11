// Compile: xcrun swiftc -parse-as-library Scripts/verify-stereo-video.swift -o build/verify-stereo-video
// Run: build/verify-stereo-video build/video-directory
import AVFoundation
import CoreImage
import VideoToolbox

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

@main enum VerifyStereoVideo {
    static func main() async {
        do { try await verify() }
        catch {
            FileHandle.standardError.write(Data("verify-stereo-video: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func verify() async throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure("Pass a capture directory") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("capture.json"))) as! [String: Any]
        let options = report["options"] as! [String: Any]
        let spatial = options["format"] as! String == "spatial"
        let width = options["width"] as! Int, height = options["height"] as! Int
        let fps = options["fps"] as! Int, expectedFrames = report["frames"] as! Int
        let asset = AVURLAsset(url: directory.appendingPathComponent("video.mov"))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CheckFailure("No video track") }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first else { throw CheckFailure("No format description") }
        if spatial {
            guard let extensions = CMFormatDescriptionGetExtensions(format) else { throw CheckFailure("Missing format extensions") }
            let ext = extensions as NSDictionary
            let expected: [(CFString, Double)] = [
                (kCMFormatDescriptionExtension_StereoCameraBaseline, (options["baseline"] as! Double) * 1000),
                (kCMFormatDescriptionExtension_HorizontalFieldOfView, (options["horizontalFOV"] as! Double) * 1000),
                (kCMFormatDescriptionExtension_HorizontalDisparityAdjustment, 0)
            ]
            for (key, value) in expected {
                guard let actual = ext[key] as? NSNumber, abs(actual.doubleValue - value) <= 0.5 else {
                    throw CheckFailure("Missing or incorrect spatial metadata: \(key)")
                }
            }
            guard ext[kCMFormatDescriptionExtension_ProjectionKind] as? String == kCMFormatDescriptionProjectionKind_Rectilinear as String else {
                throw CheckFailure("Incorrect projection")
            }
        }
        let reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if spatial {
            settings[AVVideoDecompressionPropertiesKey] = [kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String: [0, 1]]
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw CheckFailure("Cannot add decoder") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CheckFailure("Cannot start decoder") }
        let context = CIContext()
        var count = 0
        var differentStereoFrames = 0
        while let sample = output.copyNextSampleBuffer() {
            try autoreleasepool {
                let pts = sample.presentationTimeStamp.seconds
                guard abs(pts - Double(count) / Double(fps)) < 0.00001 else { throw CheckFailure("Incorrect timestamp at frame \(count)") }
                var buffers: [CVPixelBuffer] = []
                if spatial {
                    guard let tagged = sample.taggedBuffers, tagged.count == 2 else { throw CheckFailure("Missing decoded eye layers") }
                    for (eye, tag) in [CMTag.stereoView(.leftEye), .stereoView(.rightEye)].enumerated() {
                        guard let entry = tagged.first(where: { $0.tags.contains(tag) && $0.tags.contains(.videoLayerID(Int64(eye))) }),
                              case .pixelBuffer(let buffer) = entry.buffer else { throw CheckFailure("Missing eye tag") }
                        buffers.append(buffer)
                    }
                } else {
                    guard let buffer = sample.imageBuffer else { throw CheckFailure("Missing SBS pixels") }
                    buffers.append(buffer)
                }
                for buffer in buffers {
                    guard CVPixelBufferGetWidth(buffer) == width * (spatial ? 1 : 2), CVPixelBufferGetHeight(buffer) == height else {
                        throw CheckFailure("Incorrect decoded dimensions")
                    }
                }
                if spatial {
                    CVPixelBufferLockBaseAddress(buffers[0], .readOnly)
                    CVPixelBufferLockBaseAddress(buffers[1], .readOnly)
                    var differs = false
                    for y in 0..<height where !differs {
                        let a = CVPixelBufferGetBaseAddress(buffers[0])!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffers[0]))
                        let b = CVPixelBufferGetBaseAddress(buffers[1])!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffers[1]))
                        differs = memcmp(a, b, width * 4) != 0
                    }
                    CVPixelBufferUnlockBaseAddress(buffers[0], .readOnly)
                    CVPixelBufferUnlockBaseAddress(buffers[1], .readOnly)
                    if differs { differentStereoFrames += 1 }
                }
                if count == 0 || count == expectedFrames - 1 {
                    for (eye, buffer) in buffers.enumerated() {
                        try context.writePNGRepresentation(of: CIImage(cvPixelBuffer: buffer),
                            to: directory.appendingPathComponent("decoded-\(count == 0 ? "first" : "last")-\(eye).png"),
                            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    }
                }
                count += 1
            }
        }
        guard reader.status == .completed, count == expectedFrames else { throw reader.error ?? CheckFailure("Incomplete decode: \(count)/\(expectedFrames)") }
        let duration = try await asset.load(.duration).seconds
        guard abs(duration - Double(count) / Double(fps)) < 0.00001 else { throw CheckFailure("Incorrect movie duration") }
        if spatial && differentStereoFrames == 0 { throw CheckFailure("Both decoded eyes are identical in every frame") }
        print("Verified \(count) frames, \(duration) seconds, \(spatial ? "two tagged eyes + spatial metadata" : "full-width SBS"); different eye images in \(differentStereoFrames) frames")
    }
}
