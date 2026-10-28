import Foundation
import Testing

private let degrees = Double.pi / 180
private let start = Date(timeIntervalSince1970: 1_793_000_000)
private let pose = CameraPose(latitude: 37.7955, longitude: -122.3937, height: 1834.25,
                              heading: 12.5 * degrees, pitch: -41.2 * degrees)

struct CameraTrackEncodingTests {
    @Test func lineHoldsTimeSegmentAndPoseInDegrees() {
        let sample = CameraTrack.Sample(time: start.addingTimeInterval(0.017), segment: 2, pose: pose)
        #expect(CameraTrack.line(sample) == "2026-10-26T07:33:20.017Z,2,37.7955000,-122.3937000,1834.25,12.50,-41.20")
    }

    @Test func headingIsWrappedToAFullTurn() {
        var west = pose
        west.heading = -90 * degrees
        #expect(CameraTrack.line(.init(time: start, segment: 0, pose: west)).contains(",270.00,"))
        west.heading = 450 * degrees
        #expect(CameraTrack.line(.init(time: start, segment: 0, pose: west)).contains(",90.00,"))
        west.heading = -1e-9
        #expect(CameraTrack.line(.init(time: start, segment: 0, pose: west)).contains(",0.00,"))
    }

    @Test func lineRoundTrips() throws {
        let sample = CameraTrack.Sample(time: start.addingTimeInterval(1.25), segment: 1, pose: pose)
        let parsed = try #require(CameraTrack.sample(fromLine: Substring(CameraTrack.line(sample))))
        #expect(parsed.time == sample.time)
        #expect(parsed.segment == 1)
        #expect(abs(parsed.pose.latitude - pose.latitude) < 1e-7)
        #expect(abs(parsed.pose.longitude - pose.longitude) < 1e-7)
        #expect(abs(parsed.pose.height - pose.height) < 0.01)
        #expect(abs(parsed.pose.heading - pose.heading) < 0.01 * degrees)
        #expect(abs(parsed.pose.pitch - pose.pitch) < 0.01 * degrees)
    }

    @Test func headerIsNotASample() {
        #expect(CameraTrack.sample(fromLine: Substring(CameraTrack.header)) == nil)
    }

    @Test func fileNameIsTheLocalStartTime() {
        let name = CameraTrack.fileName(startedAt: start, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(name == "Track 2026-10-26 00.33.20.csv")
    }
}

struct TrackSamplerTests {
    /// Frames at `hz` for `seconds`, with the samples taken.
    private func run(_ sampler: inout TrackSampler, hz: Double, seconds: Double,
                     from t0: Date = start) -> [CameraTrack.Sample] {
        (0..<Int(hz * seconds)).compactMap { sampler.sample(pose, at: t0.addingTimeInterval(Double($0) / hz)) }
    }

    @Test(arguments: [90.0, 60.0, 30.0])
    func samplesAboutThirtyTimesASecond(displayRate: Double) {
        var sampler = TrackSampler()
        let samples = run(&sampler, hz: displayRate, seconds: 10)
        #expect(samples.count == 300)
    }

    @Test func slowerFramesAreAllKept() {
        var sampler = TrackSampler()
        #expect(run(&sampler, hz: 20, seconds: 2).count == 40)
    }

    @Test func aJumpStartsANewSegmentAtOnce() {
        var sampler = TrackSampler()
        #expect(sampler.sample(pose, at: start)?.segment == 0)
        #expect(sampler.sample(pose, at: start.addingTimeInterval(0.05))?.segment == 0)
        sampler.markJump()
        // Due straight away, even though the last sample was just now.
        #expect(sampler.sample(pose, at: start.addingTimeInterval(0.06))?.segment == 1)
        #expect(sampler.sample(pose, at: start.addingTimeInterval(0.07)) == nil)
        #expect(sampler.sample(pose, at: start.addingTimeInterval(0.1))?.segment == 1)
    }

    @Test func jumpsWithoutSamplesBetweenThemMakeOneBreak() {
        var sampler = TrackSampler()
        // A jump before anything is recorded leaves the first segment at 0.
        sampler.markJump()
        #expect(sampler.sample(pose, at: start)?.segment == 0)
        sampler.markJump()
        sampler.markJump()
        #expect(sampler.sample(pose, at: start.addingTimeInterval(1))?.segment == 1)
        sampler.markJump()
        #expect(sampler.sample(pose, at: start.addingTimeInterval(2))?.segment == 2)
    }
}

struct TrackRecorderTests {
    @Test func writesHeaderAndFlushedSamples() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraTrackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = try TrackRecorder(directory: directory, startedAt: start, flushInterval: 0.5)
        for i in 0..<30 { recorder.record(pose, at: start.addingTimeInterval(Double(i) / 30)) }
        // Past the flush interval, the first half second is on disk.
        let partial = try String(contentsOf: recorder.url, encoding: .utf8)
        #expect(partial.hasPrefix(CameraTrack.header + "\n"))
        let flushed = partial.split(separator: "\n").count - 1
        #expect(flushed >= 15 && flushed < 30)

        recorder.markJump()
        recorder.record(pose, at: start.addingTimeInterval(1))
        recorder.finish()
        let lines = try String(contentsOf: recorder.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 32)
        let samples = lines.dropFirst().compactMap(CameraTrack.sample(fromLine:))
        #expect(samples.count == 31)
        #expect(samples.last?.segment == 1)
        #expect(TrackRecorder.latestTrack(in: directory)?.lastPathComponent == recorder.url.lastPathComponent)
    }
}
