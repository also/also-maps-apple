import Foundation
import Testing

private let degrees = Double.pi / 180
private let start = Date(timeIntervalSince1970: 1_793_000_000)

private func sample(_ time: TimeInterval, segment: Int = 0, latitude: Double = 37.79, longitude: Double = -122.39,
                    height: Double = 1000, heading: Double = 0, pitch: Double = -40) -> CameraTrack.Sample {
    CameraTrack.Sample(time: start.addingTimeInterval(time), segment: segment,
                       pose: CameraPose(latitude: latitude, longitude: longitude, height: height,
                                        heading: heading * degrees, pitch: pitch * degrees))
}

struct TrackPlaybackTests {
    @Test func emptyTrackHasNoPlayback() {
        #expect(TrackPlayback(samples: []) == nil)
    }

    @Test func durationIsFirstToLastSample() throws {
        let playback = try #require(TrackPlayback(samples: [sample(0), sample(1), sample(2.5)]))
        #expect(abs(playback.duration - 2.5) < 1e-6)
    }

    @Test func betweenSamplesIsLinear() throws {
        let playback = try #require(TrackPlayback(samples: [
            sample(0, latitude: 37, longitude: -122, height: 1000, heading: 10, pitch: -40),
            sample(1, latitude: 38, longitude: -121, height: 2000, heading: 30, pitch: -20),
        ]))
        let pose = playback.pose(at: 0.25)
        #expect(abs(pose.latitude - 37.25) < 1e-6)
        #expect(abs(pose.longitude - -121.75) < 1e-6)
        #expect(abs(pose.height - 1250) < 1e-6)
        #expect(abs(pose.heading - 15 * degrees) < 1e-6)
        #expect(abs(pose.pitch - -35 * degrees) < 1e-6)
    }

    @Test func atASampleIsThatSample() throws {
        let samples = [sample(0, height: 1000), sample(1, height: 2000), sample(2, height: 1500)]
        let playback = try #require(TrackPlayback(samples: samples))
        #expect(abs(playback.pose(at: 1).height - 2000) < 1e-6)
        #expect(abs(playback.pose(at: 1).longitude - -122.39) < 1e-6)
    }

    @Test func headingGoesTheShorterWayAcrossNorth() throws {
        let playback = try #require(TrackPlayback(samples: [sample(0, heading: 350), sample(1, heading: 10)]))
        #expect(abs(playback.pose(at: 0.25).heading - 355 * degrees) < 1e-6)
        #expect(abs(playback.pose(at: 0.75).heading - 5 * degrees) < 1e-6)
        let back = try #require(TrackPlayback(samples: [sample(0, heading: 10), sample(1, heading: 350)]))
        #expect(abs(back.pose(at: 0.75).heading - 355 * degrees) < 1e-6)
    }

    @Test func longitudeGoesTheShorterWayAcrossTheAntimeridian() throws {
        let playback = try #require(TrackPlayback(samples: [sample(0, longitude: 179), sample(1, longitude: -179)]))
        #expect(abs(playback.pose(at: 0.25).longitude - 179.5) < 1e-6)
        #expect(abs(playback.pose(at: 0.75).longitude - -179.5) < 1e-6)
    }

    @Test func segmentChangeJumpsInsteadOfInterpolating() throws {
        let playback = try #require(TrackPlayback(samples: [
            sample(0, segment: 0, latitude: 37),
            sample(1, segment: 0, latitude: 37.5),
            sample(1.1, segment: 1, latitude: 48),
            sample(2, segment: 1, latitude: 49),
        ]))
        // Holds the last pose of segment 0 until segment 1's first sample.
        #expect(abs(playback.pose(at: 1.05).latitude - 37.5) < 1e-6)
        #expect(abs(playback.pose(at: 1.1).latitude - 48) < 1e-6)
        #expect(abs(playback.pose(at: 1.55).latitude - 48.5) < 1e-6)
    }

    @Test func beforeTheStartAndAfterTheEndHold() throws {
        let playback = try #require(TrackPlayback(samples: [sample(0, height: 1000), sample(1, height: 3000)]))
        #expect(abs(playback.pose(at: -1).height - 1000) < 1e-6)
        #expect(abs(playback.pose(at: 1).height - 3000) < 1e-6)
        #expect(abs(playback.pose(at: 60).height - 3000) < 1e-6)
    }

    @Test func singleSampleHoldsIt() throws {
        let playback = try #require(TrackPlayback(samples: [sample(0, height: 1234)]))
        #expect(playback.duration == 0)
        #expect(abs(playback.pose(at: 5).height - 1234) < 1e-6)
    }

    @Test func readsARecordedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try TrackRecorder(directory: directory, startedAt: start)
        recorder.record(sample(0, height: 1000).pose, at: start)
        recorder.record(sample(2, height: 3000).pose, at: start.addingTimeInterval(2))
        recorder.finish()
        let playback = try #require(try TrackPlayback(contentsOf: recorder.url))
        #expect(abs(playback.duration - 2) < 1e-3)
        #expect(abs(playback.pose(at: 1).height - 2000) < 0.01)
    }
}
