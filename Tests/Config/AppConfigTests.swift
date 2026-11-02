import Foundation
import Testing

private func notice(_ id: String, severity: String = "blocking", extra: String = "") -> String {
    #"{"id": "\#(id)", "severity": "\#(severity)", "title": "T", "body": "B"\#(extra)}"#
}

private func config(notices: [String] = [], places: String? = nil) -> Data {
    var fields = [#""notices": [\#(notices.joined(separator: ","))]"#]
    if let places { fields.append(#""places": \#(places)"#) }
    return Data("{\(fields.joined(separator: ","))}".utf8)
}

private let place = #"{"id": "a", "name": "A", "latitude": 1, "longitude": 2, "radius": 3}"#

struct AppVersionTests {
    @Test func comparesNumerically() {
        #expect(AppVersion("1.10")! > AppVersion("1.9")!)
        #expect(AppVersion("2")! > AppVersion("1.99.99")!)
    }

    @Test func missingComponentsAreZero() {
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(!(AppVersion("1.0")! < AppVersion("1.0.0")!))
        #expect(AppVersion("1.0")! < AppVersion("1.0.1")!)
    }

    @Test(arguments: ["", "1.", "1.x", "beta"])
    func rejectsAnythingElse(_ text: String) {
        #expect(AppVersion(text) == nil)
    }
}

struct AppConfigDecodingTests {
    @Test func unusableEntriesAreSkippedNotFatal() throws {
        let decoded = try AppConfig.decode(config(
            notices: [
                notice("keep"),
                notice("new-severity", severity: "shout"),
                notice("bad-version", extra: #", "maxVersion": "soon""#),
                notice("bad-date", extra: #", "expires": "tomorrow""#),
                notice("new-field", extra: #", "somethingNew": {"a": 1}"#),
            ],
            places: #"[\#(place), {"id": "broken"}, 7]"#))
        #expect(decoded.notices.map(\.id) == ["keep", "new-field"])
        #expect(decoded.places?.map(\.id) == ["a"])
    }

    @Test func invalidAndDuplicatePlacesAreDropped() throws {
        let decoded = try AppConfig.decode(config(places: """
            [\(place), \(place),
             {"id": "b", "name": "B", "latitude": 91, "longitude": 2, "radius": 3},
             {"id": "c", "name": "C", "latitude": 1, "longitude": 2, "radius": 0}]
            """))
        #expect(decoded.places?.map(\.id) == ["a"])
    }

    @Test func noUsablePlacesLeavesTheBundledOnes() throws {
        #expect(try AppConfig.decode(config()).places == nil)
        #expect(try AppConfig.decode(config(places: #"[{"id": "broken"}]"#)).places == nil)
    }

    @Test func aDifferentShapeIsAnError() {
        #expect(throws: (any Error).self) { try AppConfig.decode(Data("[]".utf8)) }
        #expect(throws: (any Error).self) { try AppConfig.decode(Data("<html>".utf8)) }
        #expect(throws: (any Error).self) { try AppConfig.decode(Data(#"{"notices": 1}"#.utf8)) }
    }
}

struct NoticeTargetingTests {
    private func decoded(_ extra: String) throws -> Notice {
        try #require(AppConfig.decode(config(notices: [notice("n", extra: extra)])).notices.first)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func appliesEverywhereByDefault() throws {
        #expect(try decoded("").applies(platform: "ios", version: AppVersion("1.0")!, keySource: "app", now: now))
    }

    @Test func versionRangeIsInclusive() throws {
        let notice = try decoded(#", "minVersion": "1.2", "maxVersion": "1.3""#)
        let applies = { notice.applies(platform: "ios", version: AppVersion($0)!, keySource: "app", now: self.now) }
        #expect(!applies("1.1.9"))
        #expect(applies("1.2"))
        #expect(applies("1.3.0"))
        #expect(!applies("1.3.1"))
    }

    @Test func filtersByPlatform() throws {
        let notice = try decoded(#", "platforms": ["tvos", "macos"]"#)
        #expect(notice.applies(platform: "tvos", version: AppVersion("1")!, keySource: "app", now: now))
        #expect(!notice.applies(platform: "ios", version: AppVersion("1")!, keySource: "app", now: now))
    }

    @Test func filtersByKeySource() throws {
        let notice = try decoded(#", "keySource": "app""#)
        #expect(notice.applies(platform: "ios", version: AppVersion("1")!, keySource: "app", now: now))
        #expect(!notice.applies(platform: "ios", version: AppVersion("1")!, keySource: "own", now: now))
    }

    @Test func expires() throws {
        let notice = try decoded(#", "expires": "2027-01-15T08:00:00Z""#)
        let expiry = try #require(notice.expires)
        #expect(notice.applies(platform: "ios", version: AppVersion("1")!, keySource: "app", now: expiry - 1))
        #expect(!notice.applies(platform: "ios", version: AppVersion("1")!, keySource: "app", now: expiry))
    }
}

@MainActor
struct AppConfigStoreTests {
    private let url = URL(string: "https://example.test/config.json")!
    private let cacheFile = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appending(path: "config.json")
    private let defaults = UserDefaults(suiteName: UUID().uuidString)!

    private func store(now: @escaping () -> Date = Date.init,
                       _ fetch: @escaping AppConfigStore.Fetch) -> AppConfigStore {
        AppConfigStore(url: url, cacheFile: cacheFile, defaults: defaults, fetch: fetch,
                       platform: "ios", version: AppVersion("1.0")!, now: now)
    }

    private func serving(_ data: Data, status: Int = 200) -> AppConfigStore.Fetch {
        let url = url
        return { _ in (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!) }
    }

    @Test func failuresWithNothingSavedLeaveTheAppRunning() async {
        let failing: [AppConfigStore.Fetch] = [
            { _ in throw URLError(.notConnectedToInternet) },
            serving(Data("<html>".utf8)),
            serving(config(notices: [notice("kill")]), status: 500),
        ]
        for fetch in failing {
            let store = store(fetch)
            await store.refresh()
            #expect(store.config == nil)
            #expect(store.blocking == nil)
        }
    }

    @Test func aBadResponseKeepsTheLastGoodConfig() async {
        var responses = [config(places: "[\(place)]"), Data("oops".utf8)]
        let good = store(serving(responses.removeFirst()))
        await good.refresh()
        let bad = store(serving(responses.removeFirst()))
        #expect(bad.config?.places?.first?.id == "a")
        await bad.refresh()
        #expect(bad.config?.places?.first?.id == "a")
    }

    @Test func aSavedBlockAppliesAtOnceAndCanBeLifted() async {
        await store(serving(config(notices: [notice("kill")]))).refresh()

        let store = store(serving(config()))
        #expect(store.blocking?.id == "kill")
        await store.refresh()
        #expect(store.blocking == nil)
    }

    @Test func aSavedBlockExpiresEvenOffline() async {
        let expiring = notice("kill", extra: #", "expires": "2027-01-15T08:00:00Z""#)
        var time = ISO8601DateFormatter().date(from: "2027-01-15T07:00:00Z")!
        await store(serving(config(notices: [expiring]))).refresh()

        let store = store(now: { time }) { _ in throw URLError(.notConnectedToInternet) }
        #expect(store.blocking != nil)
        time += 2 * 60 * 60
        await store.refresh()
        #expect(store.blocking == nil)
    }

    @Test func noticesStayDismissed() async {
        let data = config(notices: [notice("one", severity: "info"), notice("two", severity: "info")])
        let first = store(serving(data))
        await first.refresh()
        #expect(first.notice?.id == "one")
        first.dismiss(first.notice!)
        #expect(first.notice?.id == "two")

        let next = store(serving(data))
        #expect(next.notice?.id == "two")
    }

    @Test func aBlockIsNotDismissible() async {
        let store = store(serving(config(notices: [notice("kill")])))
        await store.refresh()
        store.dismiss(store.blocking!)
        #expect(store.blocking?.id == "kill")
    }

    @Test func refreshesAreSpacedOutUnlessForced() async {
        var fetches = 0
        var time = Date(timeIntervalSince1970: 0)
        let data = config()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let store = store(now: { time }) { _ in
            fetches += 1
            return (data, response)
        }
        await store.refresh()
        await store.refresh()
        #expect(fetches == 1)
        await store.refresh(force: true)
        #expect(fetches == 2)
        time += 31
        await store.refresh()
        #expect(fetches == 3)
    }
}

struct PlaceSteppingTests {
    private let places = ["a", "b", "c"].map {
        Place(id: $0, name: $0, latitude: 0, longitude: 0, radius: 1)
    }

    @Test func wraps() {
        #expect(PlaceLibrary.place(in: places, stepping: 1, from: "c").id == "a")
        #expect(PlaceLibrary.place(in: places, stepping: -1, from: "a").id == "c")
    }

    @Test func startsFromTheEndsWithoutACurrentPlace() {
        for id in [nil, "removed"] {
            #expect(PlaceLibrary.place(in: places, stepping: 1, from: id).id == "a")
            #expect(PlaceLibrary.place(in: places, stepping: -1, from: id).id == "c")
        }
    }
}
