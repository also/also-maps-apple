import Foundation
import Testing

private func place(_ string: String) -> Place? {
    PlaceLink.place(from: URL(string: string)!)
}

struct PlaceLinkTests {
    @Test(arguments: [
        "https://maps.also.dev/p#lat=48.8584&lon=2.2945&r=400&h=120",
        "alsomaps://p#lat=48.8584&lon=2.2945&r=400&h=120",
        "alsomaps:///p#lat=48.8584&lon=2.2945&r=400&h=120",
        "https://example.com/p#lat=48.8584&lon=2.2945&r=400&h=120",
        "http://localhost:8080/p/#lat=48.8584&lon=2.2945&r=400&h=120",
    ])
    func readsEveryField(_ link: String) throws {
        let p = try #require(place(link))
        #expect(p.latitude == 48.8584)
        #expect(p.longitude == 2.2945)
        #expect(p.radius == 400)
        #expect(p.heading == 120)
        #expect(p.name == "48.8584, 2.2945")
    }

    @Test func eachLinkGetsItsOwnId() throws {
        let link = "alsomaps://p#lat=1&lon=2"
        let a = try #require(place(link)), b = try #require(place(link))
        #expect(a.id != b.id)
    }

    @Test func optionalFieldsDefault() throws {
        let p = try #require(place("https://maps.also.dev/p#lat=-33.8568&lon=151.2153"))
        #expect(p.radius == PlaceLink.defaultRadius)
        #expect(p.heading == 0)
        #expect(p.name == "-33.8568, 151.2153")
    }

    @Test func unusableOptionalFieldsDefault() throws {
        let p = try #require(place("alsomaps://p#lat=1&lon=2&r=-5&h=north"))
        #expect(p.radius == PlaceLink.defaultRadius)
        #expect(p.heading == 0)
        #expect(try #require(place("alsomaps://p#lat=1&lon=2&r=1e12")).radius == PlaceLink.defaultRadius)
    }

    @Test func headingWrapsIntoOneTurn() throws {
        #expect(try #require(place("alsomaps://p#lat=1&lon=2&h=-90")).heading == 270)
        #expect(try #require(place("alsomaps://p#lat=1&lon=2&h=450")).heading == 90)
    }

    /// Links carry no text: a text field is an unknown key, and doesn't
    /// reach the app.
    @Test func ignoresText() throws {
        let p = try #require(place("alsomaps://p#lat=1&lon=2&name=Caf%C3%A9+de+Flore"))
        #expect(p.name == "1.0000, 2.0000")
    }

    @Test func decodesFormEncodedValues() throws {
        // An encoded key, a + sign and padding spaces.
        let p = try #require(place("alsomaps://p#%6C%61%74=%2B1&lon=+2+&h=%2D90"))
        #expect(p.latitude == 1)
        #expect(p.longitude == 2)
        #expect(p.heading == 270)
        // An encoded & stays in the value rather than splitting fields.
        #expect(place("alsomaps://p#lat=1%26lon%3D2") == nil)
    }

    @Test func ignoresUnknownKeysAndOrder() throws {
        let p = try #require(place("alsomaps://p#utm=x&zoom=3&lon=2&lat=1&&flag"))
        #expect(p.latitude == 1)
        #expect(p.longitude == 2)
    }

    @Test func acceptsRangeEdges() {
        #expect(place("alsomaps://p#lat=90&lon=180") != nil)
        #expect(place("alsomaps://p#lat=-90&lon=-180") != nil)
    }

    @Test(arguments: [
        "https://maps.also.dev/#lat=1&lon=2",
        "https://maps.also.dev/place#lat=1&lon=2",
        "https://maps.also.dev/p/extra#lat=1&lon=2",
        "https://maps.also.dev/x/p#lat=1&lon=2",
        "alsomaps://place#lat=1&lon=2",
        "alsomaps://p/x#lat=1&lon=2",
    ])
    func rejectsOtherPaths(_ link: String) {
        #expect(place(link) == nil)
    }

    @Test(arguments: [
        "https://maps.also.dev/p",
        "https://maps.also.dev/p#",
        "https://maps.also.dev/p?lat=1&lon=2",
        "alsomaps://p#lat=1",
        "alsomaps://p#lon=2",
        "alsomaps://p#lat=&lon=2",
        "alsomaps://p#lat=abc&lon=2",
        "alsomaps://p#lat=1,5&lon=2",
        "alsomaps://p#lat=nan&lon=2",
        "alsomaps://p#lat=1&lon=inf",
        "alsomaps://p#lat=90.1&lon=2",
        "alsomaps://p#lat=-91&lon=2",
        "alsomaps://p#lat=1&lon=180.5",
        "alsomaps://p#lat=1&lon=-200",
        "alsomaps://p#lat=%ZZ&lon=2",
    ])
    func rejectsInvalidInput(_ link: String) {
        #expect(place(link) == nil)
    }
}
