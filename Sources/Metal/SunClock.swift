import Foundation

/// The sun study's chosen instant, read and set as a calendar day and a
/// time of day in the place's time zone: "21 December at 08:00 in
/// Lisbon", whatever zone the device is in. Pure Foundation.
struct SunClock: Equatable {
    var instant: Date
    var timeZone: TimeZone

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The local midnight starting the instant's day.
    var startOfDay: Date { calendar.startOfDay(for: instant) }

    /// Seconds from local midnight to the next: 23 or 25 hours when the
    /// clocks change.
    var dayLength: TimeInterval {
        let start = startOfDay
        return (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
            .timeIntervalSince(start)
    }

    /// Minutes since local midnight (elapsed, so 01:30 on the morning the
    /// clocks go forward at 01:00 isn't a time it can be). Setting it keeps
    /// the day and clamps to it.
    var minutesOfDay: Double {
        get { instant.timeIntervalSince(startOfDay) / 60 }
        set { instant = startOfDay.addingTimeInterval(min(max(newValue, 0), dayLength / 60 - 1) * 60) }
    }

    /// Any instant on the chosen day, as a date picker gives it. Setting it
    /// moves to that local day at the same wall-clock time.
    var day: Date {
        get { instant }
        set {
            var components = calendar.dateComponents([.year, .month, .day], from: newValue)
            let time = calendar.dateComponents([.hour, .minute, .second], from: instant)
            components.hour = time.hour
            components.minute = time.minute
            components.second = time.second
            instant = calendar.date(from: components) ?? instant
        }
    }

    /// Moves to another place's zone keeping the wall-clock time and day
    /// ("08:00 on 21 December"), not the instant.
    mutating func changeTimeZone(to zone: TimeZone) {
        guard zone != timeZone else { return }
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        timeZone = zone
        instant = calendar.date(from: components) ?? instant
    }

    /// A time-lapse step: forward `seconds`, wrapping to the start of the
    /// same local day, so it loops over the day being studied.
    mutating func advance(by seconds: TimeInterval) {
        let length = dayLength
        guard length > 0, seconds.isFinite else { return }
        var elapsed = instant.timeIntervalSince(startOfDay) + seconds
        elapsed = elapsed.truncatingRemainder(dividingBy: length)
        if elapsed < 0 { elapsed += length }
        instant = startOfDay.addingTimeInterval(elapsed)
    }

    /// The zone a longitude falls in by the hour (15° each), with no
    /// daylight saving: a stand-in until the place's real zone is known.
    static func approximateTimeZone(longitude: Double) -> TimeZone {
        let hours = min(max((longitude / 15).rounded(), -12), 14)
        return TimeZone(secondsFromGMT: Int(hours) * 3600) ?? .gmt
    }
}
