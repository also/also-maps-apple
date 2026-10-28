import Foundation

/// Camera tracks: the camera's position and heading over time, recorded to a
/// text file for converting to geo formats, replaying or drawing later.
///
/// File format (CSV, UTF-8, one sample per line, append-only):
///
///     time,segment,latitude,longitude,height,heading,pitch
///     2026-10-27T14:05:33.017Z,0,37.7955000,-122.3937000,1834.25,12.50,-41.20
///
/// - `time`: ISO 8601 UTC with milliseconds.
/// - `segment`: starts at 0 and goes up by one after each camera jump (going
///   to a place, restoring a view), so the track isn't drawn across a jump.
/// - `latitude`, `longitude`: degrees, WGS84.
/// - `height`: metres above the WGS84 ellipsoid (not mean sea level).
/// - `heading`: degrees clockwise from north, 0 ..< 360.
/// - `pitch`: degrees, 0 level, −90 straight down.
enum CameraTrack {
    static let header = "time,segment,latitude,longitude,height,heading,pitch"
    static let fileExtension = "csv"

    struct Sample: Equatable {
        var time: Date
        var segment: Int
        var pose: CameraPose
    }

    private static let timeFormat: Date.ISO8601FormatStyle =
        .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)

    /// ISO 8601 UTC, rounded to the millisecond (the format style truncates).
    static func timestamp(_ time: Date) -> String {
        let milliseconds = Int64((time.timeIntervalSince1970 * 1000).rounded())
        let (seconds, fraction) = milliseconds.quotientAndRemainder(dividingBy: 1000)
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds))
            .formatted(.iso8601)  // 2026-10-26T07:33:20Z
        return String(format: "%@.%03dZ", String(whole.dropLast()), Int(fraction))
    }

    /// One CSV line, without the newline.
    static func line(_ sample: Sample) -> String {
        let pose = sample.pose
        // Wrapped after rounding, so just west of north isn't "360.00".
        var heading = ((pose.heading * 180 / .pi) * 100).rounded() / 100
        heading = heading.truncatingRemainder(dividingBy: 360)
        heading = heading < 0 ? heading + 360 : abs(heading)  // No "-0.00".
        return [timestamp(sample.time),
                String(sample.segment),
                String(format: "%.7f", pose.latitude),
                String(format: "%.7f", pose.longitude),
                String(format: "%.2f", pose.height),
                String(format: "%.2f", heading),
                String(format: "%.2f", pose.pitch * 180 / .pi)].joined(separator: ",")
    }

    /// Parses a line written by `line(_:)`; nil for the header or anything
    /// else. Angles come back in radians, as CameraPose holds them.
    static func sample(fromLine line: Substring) -> Sample? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 7,
              let time = try? timeFormat.parse(String(fields[0])),
              let segment = Int(fields[1]),
              let latitude = Double(fields[2]), let longitude = Double(fields[3]),
              let height = Double(fields[4]),
              let heading = Double(fields[5]), let pitch = Double(fields[6])
        else { return nil }
        return Sample(time: time, segment: segment,
                      pose: CameraPose(latitude: latitude, longitude: longitude, height: height,
                                       heading: heading * .pi / 180, pitch: pitch * .pi / 180))
    }

    /// The file name for a recording started at `date`, in local time, e.g.
    /// "Track 2026-10-27 14.05.33.csv".
    static func fileName(startedAt date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Track \(formatter.string(from: date)).\(fileExtension)"
    }
}

/// Decides which frames become samples and which segment each is in: at most
/// `rate` samples a second, and a new segment after each jump that has
/// samples before it.
struct TrackSampler {
    var rate = 30.0
    private var lastTime: Date?
    private var segment = 0
    private var segmentHasSamples = false
    private var jumped = false

    init(rate: Double = 30) { self.rate = rate }

    /// The camera jumped: the next sample starts a new segment. Sampling is
    /// due again at once, so the segment starts where the jump landed.
    mutating func markJump() {
        jumped = true
        lastTime = nil
    }

    /// The sample for this frame, or nil when one isn't due. Frames come at
    /// the display rate (90 Hz on device), so a little slack keeps every
    /// third frame rather than every fourth.
    mutating func sample(_ pose: CameraPose, at time: Date) -> CameraTrack.Sample? {
        if let lastTime, time.timeIntervalSince(lastTime) < 0.9 / rate { return nil }
        if jumped {
            jumped = false
            if segmentHasSamples {
                segment += 1
                segmentHasSamples = false
            }
        }
        lastTime = time
        segmentHasSamples = true
        return CameraTrack.Sample(time: time, segment: segment, pose: pose)
    }
}

/// Records one track to a file: samples are buffered and appended every
/// `flushInterval`, so a crash loses at most that much.
final class TrackRecorder {
    let url: URL
    private var sampler: TrackSampler
    private let handle: FileHandle
    private var buffer = ""
    private var lastFlush: Date
    private let flushInterval: TimeInterval
    private(set) var sampleCount = 0

    /// Creates the file (failing if it exists) and writes the header.
    init(directory: URL, startedAt start: Date = Date(), rate: Double = 30,
         flushInterval: TimeInterval = 0.5) throws {
        url = directory.appendingPathComponent(CameraTrack.fileName(startedAt: start))
        guard FileManager.default.createFile(atPath: url.path,
                                             contents: Data((CameraTrack.header + "\n").utf8)),
              let handle = try? FileHandle(forWritingTo: url)
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        try handle.seekToEnd()
        self.handle = handle
        sampler = TrackSampler(rate: rate)
        lastFlush = start
        self.flushInterval = flushInterval
    }

    deinit { try? handle.close() }

    func markJump() { sampler.markJump() }

    /// Returns the sample recorded, if one was due.
    @discardableResult
    func record(_ pose: CameraPose, at time: Date = Date()) -> CameraTrack.Sample? {
        guard let sample = sampler.sample(pose, at: time) else { return nil }
        buffer += CameraTrack.line(sample) + "\n"
        sampleCount += 1
        if time.timeIntervalSince(lastFlush) >= flushInterval {
            flush()
            lastFlush = time
        }
        return sample
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: Data(buffer.utf8))
        } catch {
            print("[AlsoMaps] couldn't write track \(url.lastPathComponent): \(error)")
        }
        buffer = ""
    }

    /// Flushes and closes the file.
    func finish() {
        flush()
        try? handle.close()
    }

    /// The most recent track in `directory` (names sort by start time).
    static func latestTrack(in directory: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == CameraTrack.fileExtension && $0.lastPathComponent.hasPrefix("Track ") }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }
}
