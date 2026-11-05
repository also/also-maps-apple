import Foundation
import Testing

struct SunClockTests {
    private let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func date(_ string: String) -> Date {
        try! Date(string, strategy: .iso8601)
    }

    @Test
    func readsAndSetsTheTimeOfDayInThePlacesZone() {
        var clock = SunClock(instant: date("2024-12-21T08:00:00Z"), timeZone: tokyo)
        // 08:00 UTC is 17:00 in Tokyo.
        #expect(clock.minutesOfDay == 17 * 60)
        clock.minutesOfDay = 7 * 60 + 30
        #expect(clock.instant == date("2024-12-20T22:30:00Z"))
    }

    @Test
    func changingTheDayKeepsTheWallClockTime() {
        var clock = SunClock(instant: date("2024-06-21T07:00:00Z"), timeZone: lisbon)  // 08:00 summer time
        clock.day = date("2024-12-21T12:00:00Z")
        #expect(clock.instant == date("2024-12-21T08:00:00Z"))  // 08:00 winter time
    }

    @Test
    func changingTheZoneKeepsTheWallClockTimeNotTheInstant() {
        var clock = SunClock(instant: date("2024-12-21T08:00:00Z"), timeZone: lisbon)
        clock.changeTimeZone(to: tokyo)
        #expect(clock.instant == date("2024-12-20T23:00:00Z"))
        #expect(clock.minutesOfDay == 8 * 60)
    }

    @Test
    func timeLapseLoopsOverTheSameDay() {
        var clock = SunClock(instant: date("2024-12-21T22:00:00Z"), timeZone: lisbon)
        clock.advance(by: 3 * 3600)
        #expect(clock.instant == date("2024-12-21T01:00:00Z"))
    }

    @Test
    func theDayTheClocksGoForwardIs23Hours() {
        var clock = SunClock(instant: date("2024-03-10T17:00:00Z"), timeZone: newYork)
        #expect(clock.dayLength == 23 * 3600)
        clock.minutesOfDay = 2000
        #expect(clock.minutesOfDay == 23 * 60 - 1)
    }

    @Test
    func approximatesAZoneFromLongitude() {
        #expect(SunClock.approximateTimeZone(longitude: -74).secondsFromGMT() == -5 * 3600)
        #expect(SunClock.approximateTimeZone(longitude: 139.7).secondsFromGMT() == 9 * 3600)
        #expect(SunClock.approximateTimeZone(longitude: 180).secondsFromGMT() == 12 * 3600)
    }
}
