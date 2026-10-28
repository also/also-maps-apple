import Foundation

/// A recorded track as a camera over time, for playing it back: the pose at
/// any time since the first sample.
///
/// Between two samples in a segment the pose is interpolated: latitude,
/// height and pitch linearly, longitude and heading the shorter way round.
/// Samples are about 30 Hz, so the straight line in degrees is as good as
/// the straight line in space. Across a segment change (a camera jump) it
/// isn't interpolated: the earlier sample holds until the next segment's
/// first sample's time, then the camera jumps there, as it did recording.
struct TrackPlayback {
    /// In time order, at least one.
    let samples: [CameraTrack.Sample]

    /// Nil if there are no samples. Samples out of time order are dropped.
    init?<S: Sequence>(samples: S) where S.Element == CameraTrack.Sample {
        var ordered: [CameraTrack.Sample] = []
        for sample in samples where ordered.last.map({ sample.time >= $0.time }) ?? true {
            ordered.append(sample)
        }
        guard !ordered.isEmpty else { return nil }
        self.samples = ordered
    }

    /// The track in a file written by TrackRecorder; nil if it has no samples.
    init?(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self.init(samples: text.split(whereSeparator: \.isNewline).lazy.compactMap(CameraTrack.sample(fromLine:)))
    }

    /// Seconds from the first sample to the last.
    var duration: TimeInterval {
        samples[samples.count - 1].time.timeIntervalSince(samples[0].time)
    }

    /// The camera `time` seconds after the first sample: the first pose
    /// before it, the last after the end.
    func pose(at time: TimeInterval) -> CameraPose {
        let start = samples[0].time
        let t = start.addingTimeInterval(time)
        // The first sample after t; the one before it is at or before t.
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time <= t { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return samples[0].pose }
        guard low < samples.count else { return samples[samples.count - 1].pose }
        let a = samples[low - 1], b = samples[low]
        guard a.segment == b.segment else { return a.pose }
        let span = b.time.timeIntervalSince(a.time)
        let f = span > 0 ? t.timeIntervalSince(a.time) / span : 0
        return Self.interpolate(a.pose, b.pose, f)
    }

    /// `f` of the way from `a` to `b`.
    static func interpolate(_ a: CameraPose, _ b: CameraPose, _ f: Double) -> CameraPose {
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        /// The shorter way round, wrapped into 0 ..< period.
        func lerpAngle(_ x: Double, _ y: Double, period: Double) -> Double {
            let angle = (x + remainder(y - x, period) * f).truncatingRemainder(dividingBy: period)
            return angle < 0 ? angle + period : angle
        }
        var longitude = lerpAngle(a.longitude, b.longitude, period: 360)
        if longitude >= 180 { longitude -= 360 }
        return CameraPose(latitude: lerp(a.latitude, b.latitude),
                          longitude: longitude,
                          height: lerp(a.height, b.height),
                          heading: lerpAngle(a.heading, b.heading, period: 2 * .pi),
                          pitch: lerp(a.pitch, b.pitch))
    }
}
