import Foundation
import Testing
import simd

struct VideoTests {
    @Test func stereoConvergesWithoutVerticalDisparity() {
        func ndc(_ x: Float, _ y: Float, _ distance: Float, eye: Float) -> SIMD3<Float> {
            let matrix = StereoCamera.projection(eyeX: eye, convergence: 100, horizontalFOV: .pi / 2,
                                                 aspect: 16 / 9, near: 0.1, far: 10000)
            let clip = matrix * SIMD4(x, y, -distance, 1)
            return SIMD3(clip.x, clip.y, clip.z) / clip.w
        }
        for distance: Float in [10, 100, 1000] {
            let left = ndc(3, 2, distance, eye: -0.032)
            let right = ndc(3, 2, distance, eye: 0.032)
            #expect(abs(left.y - right.y) < 0.000001)
            if distance == 100 { #expect(abs(left.x - right.x) < 0.000001) }
            if distance < 100 { #expect(left.x > right.x) }
            if distance > 100 { #expect(left.x < right.x) }
        }
    }

    @Test func journeyIncludesEndpointsAndShortestHeadingAcrossNorth() throws {
        let options = try VideoOptions.parse(["--from", "0,179,100,350,-20", "--to", "0,-179,200,10,-10",
                                              "--duration", "1", "--fps", "3"])
        let journey = try VideoJourney(options)
        #expect(journey.frameCount == 3)
        #expect(journey.pose(frame: 0) == options.initialPose)
        let middle = journey.pose(frame: 1)
        #expect(abs(abs(middle.longitude) - 180) < 0.000001)
        #expect(abs(middle.heading) < 0.000001)
        #expect(middle.height == 150)
        let last = journey.pose(frame: 2)
        #expect(abs(last.longitude - options.finalPose.longitude) < 0.000001)
        #expect(abs(last.height - options.finalPose.height) < 0.000001)
    }

    @Test func miniatureScaleSeparatesGeographicAndPhysicalBaseline() throws {
        let options = try VideoOptions.parse(["--google", "--baseline", "64", "--world-scale", "0.001"])
        #expect(options.baseline == 64)
        #expect(options.worldBaseline == 64)
        #expect(options.convergenceDistance == 1000)
    }

    @Test func durationRoundsToWholeFramesAndRejectsSingleFrameJourneys() throws {
        let options = try VideoOptions.parse(["--duration", "1.01", "--fps", "30"])
        #expect(try VideoJourney(options).frameCount == 31)
        let tooShort = try VideoOptions.parse(["--duration", "0.05", "--fps", "1"])
        #expect(throws: RenderCLIError.self) { try VideoJourney(tooShort) }
    }

    @Test(arguments: [["--fps", "0"], ["--width", "1279"], ["--height", "8192"], ["--duration", "nan"],
        ["--duration", "10000"], ["--baseline", "0"], ["--world-scale", "0"], ["--convergence", "0"],
        ["--fov", "180"], ["--from", "1,2,3"], ["--from", "91,0,10,0,0"], ["--from", "0,0,10,0,-91"],
        ["--track", "x.csv"], ["--google", "--track", "x.csv", "--from", "0,0,10,0,0"],
        ["--start", "2"], ["--format", "fake"], ["--width"], ["--world-scale", "0.0001", "--convergence", "1"]])
    func invalidOptionsFail(arguments: [String]) {
        #expect(throws: RenderCLIError.self) { try VideoOptions.parse(arguments) }
    }

    @Test func trackCropRetainsHardCutsAndRejectsMalformedRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = CameraPose(latitude: 40, longitude: -73, height: 600, heading: 0, pitch: 0)
        let second = CameraPose(latitude: 41, longitude: -73, height: 600, heading: 0, pitch: 0)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let text = CameraTrack.header + "\n" + CameraTrack.line(.init(time: start, segment: 0, pose: first)) + "\n"
            + CameraTrack.line(.init(time: start.addingTimeInterval(2), segment: 1, pose: second)) + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let options = try VideoOptions.parse(["--google", "--track", url.path, "--duration", "2", "--fps", "2"])
        let journey = try VideoJourney(options)
        #expect(journey.pose(frame: 2) == first)
        #expect(journey.pose(frame: 3) == second)
        var beyond = options; beyond.start = 1
        #expect(throws: RenderCLIError.self) { try VideoJourney(beyond) }
        try (text + "broken row\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: RenderCLIError.self) { try VideoJourney(options) }
    }
}
