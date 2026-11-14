import Foundation
import Testing

private func feature(_ name: String, rank: Int = 5) -> PlaceContext.Feature {
    PlaceContext.Feature(id: name.hashValue, wikidata: nil, name: name, localName: nil, kind: "Populated place",
                         state: nil, country: nil, countryCode: "US", population: nil, rank: rank)
}

private func region(_ name: String, kind: String?, country: String? = nil, code: String? = nil,
                    sharesName: Bool = false) -> PlaceContext.Region {
    PlaceContext.Region(id: name.hashValue, wikidata: nil, name: name, localName: nil, kind: kind, country: country,
                        countryCode: code, sharesNameWithPlace: sharesName)
}

private func surroundings(urban: String? = nil, nearby: [PlaceContext.Nearby] = [], state: PlaceContext.Region? = nil,
                          waters: [PlaceContext.Region] = []) -> PlaceContext.Surroundings {
    PlaceContext.Surroundings(latitude: 42.27, longitude: -71.8, urbanArea: urban.map { feature($0) },
                              nearby: nearby, state: state, waters: waters)
}

private func context(height: Double = 9_144, below: PlaceContext.Surroundings, center: PlaceContext.ViewCenter? = nil) -> PlaceContext {
    PlaceContext(camera: PlaceContext.Camera(latitude: below.latitude, longitude: below.longitude, height: height, heading: 0),
                 below: below, viewCenter: center)
}

struct PlaceSuggestionsTests {
    @Test(arguments: [
        (100.0, "300 ft"),
        (300, "1,000 ft"),
        (1_400, "4,500 ft"),
        (9_144, "30,000 ft"),
        (12_500, "41,000 ft"),
        (20_000, "12 mi"),
        (400_000, "250 mi"),
    ])
    func altitudes(meters: Double, phrase: String) {
        #expect(PlaceSuggestions.altitudePhrase(meters) == phrase)
    }

    @Test func relativeToANearbyPlace() {
        let near = PlaceContext.Nearby(place: feature("Boston"), distance: 64_000, bearingFromPlace: 265)
        #expect(PlaceSuggestions.relativePhrase(near) == "40 mi W of Boston")
        let c = context(below: surroundings(nearby: [near], state: region("Massachusetts", kind: "State", code: "US")))
        #expect(PlaceSuggestions.description(of: c) == "30,000 ft, 40 mi W of Boston")
        #expect(PlaceSuggestions.names(for: c).contains("Near Boston") == false)
        #expect(PlaceSuggestions.names(for: c).contains("40 mi W of Boston"))
    }

    @Test func statesOutsideTheUSIncludeTheirCountry() {
        #expect(PlaceSuggestions.stateName(region("Nevada", kind: "State", country: "United States of America", code: "US")) == "Nevada")
        #expect(PlaceSuggestions.stateName(region("Entre Ríos", kind: "Province", country: "Argentina", code: "AR")) == "Entre Ríos, Argentina")
    }

    /// Over Ronda at 30,000 ft: the nearest place that counts is too far to
    /// name the point, so it's named by its province, with the country.
    @Test func shortNamesKeepTheCountry() {
        let marbella = PlaceContext.Nearby(place: feature("Marbella"), distance: 34_000, bearingFromPlace: 315)
        let malaga = region("Málaga", kind: "Autonomous Community", country: "Spain", code: "ES", sharesName: true)
        let names = PlaceSuggestions.names(for: context(below: surroundings(nearby: [marbella], state: malaga)))
        #expect(names.contains("Málaga region, Spain"))
        #expect(!names.contains("Málaga"))
    }

    @Test func statesNamedLikeACityAreQualified() {
        // Trusted types.
        #expect(PlaceSuggestions.stateName(region("New York", kind: "State", country: "United States of America", code: "US", sharesName: true)) == "New York State")
        #expect(PlaceSuggestions.stateName(region("Ankara", kind: "Province", country: "Turkey", code: "TR", sharesName: true)) == "Ankara Province, Turkey")
        #expect(PlaceSuggestions.stateName(region("Osaka", kind: "Prefecture", country: "Japan", code: "JP", sharesName: true)) == "Osaka Prefecture, Japan")
        // Untrusted types: Spain's provinces are labeled "Autonomous Community".
        #expect(PlaceSuggestions.stateName(region("Málaga", kind: "Autonomous Community", country: "Spain", code: "ES", sharesName: true)) == "Málaga region, Spain")
        #expect(PlaceSuggestions.stateName(region("Leicestershire", kind: "Kingdom", country: "United Kingdom", code: "GB", sharesName: true)) == "Leicestershire region, United Kingdom")
        // A unit that is itself the city.
        #expect(PlaceSuggestions.stateName(region("Pasay", kind: "Highly Urbanized City", country: "Philippines", code: "PH", sharesName: true)) == "Pasay, Philippines")
        // Not named like a city.
        #expect(PlaceSuggestions.stateName(region("Nevada", kind: "State", country: "United States of America", code: "US")) == "Nevada")
    }

    @Test(arguments: [
        ("Gulf of Maine", "gulf", "the Gulf of Maine"),
        ("North Atlantic Ocean", "ocean", "the North Atlantic Ocean"),
        ("Bosporus", "strait", "the Bosporus"),
        ("Chesapeake Bay", "bay", "Chesapeake Bay"),
        ("Long Island Sound", "sound", "Long Island Sound"),
        ("Bay of Fundy", "bay", "the Bay of Fundy"),
    ])
    func waterArticles(name: String, kind: String, phrase: String) {
        #expect(PlaceSuggestions.waterName(region(name, kind: kind)) == phrase)
    }

    @Test func coordinatesWhenNothingElseApplies() {
        let c = context(below: surroundings())
        #expect(PlaceSuggestions.description(of: c) == "30,000 ft over 42.27° N, 71.80° W")
    }

    @Test func lookingAtTheSamePlaceIsntLookingToward() {
        let center = PlaceContext.ViewCenter(surroundings: surroundings(urban: "Boston"), distance: 3_000, bearing: 90)
        let names = PlaceSuggestions.names(for: context(below: surroundings(urban: "Boston"), center: center))
        #expect(!names.contains { $0.contains("looking toward") })
        #expect(names.first == "30,000 ft over Boston")
    }

    @Test func noDuplicates() {
        let names = PlaceSuggestions.names(for: context(below: surroundings(urban: "Boston", state: region("Massachusetts", kind: "State", code: "US"))))
        #expect(names.count == Set(names.map { $0.lowercased() }).count)
    }
}

struct KnownNameFilterTests {
    let known = ["Worcester", "Boston", "Massachusetts", "North Atlantic Ocean"]

    @Test(arguments: [
        "Over Worcester",
        "Boston from the West",
        "Worcester Skyline at Sunset",
        "Central Massachusetts",
        "High Over the North Atlantic",
    ])
    func keeps(_ suggestion: String) {
        #expect(PlaceSuggestions.usesOnlyKnownNames(suggestion, known: known))
    }

    @Test(arguments: [
        "Over Springfield",
        "Boston and Providence",
        "A Quiet Evening",
    ])
    func drops(_ suggestion: String) {
        #expect(!PlaceSuggestions.usesOnlyKnownNames(suggestion, known: known))
    }
}
