import Foundation

/// A path through space over time, which the map can draw as a tube
/// (TrackPath) and fly along (TrackPlayback): the camera's own, recorded by
/// TrackRecorder (CameraTrack), or GPS fixes from a file (KMLFile).
struct Track {
    /// One point of a track: where it was, which way it faced, and when.
    struct Sample: Equatable {
        var time: Date
        /// Starts at 0 and goes up by one at each break, so the track isn't
        /// drawn or flown across a gap.
        var segment: Int
        var pose: CameraPose
    }

    var name: String
    /// In time order.
    var samples: [Sample]

    /// Where it starts, for going there before playing it.
    var start: Place? {
        guard let pose = samples.first?.pose else { return nil }
        return Place(id: "track", name: name, latitude: pose.latitude, longitude: pose.longitude, radius: 2_000)
    }
}
