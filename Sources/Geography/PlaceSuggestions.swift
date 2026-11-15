import Foundation

/// Phrases built from a PlaceContext, in American English, with feet and
/// miles: "30,000 ft over Worcester", "Over Worcester, looking toward
/// Boston". The same input always gives the same output, on every platform.
enum PlaceSuggestions {
    /// Names to offer for a saved place, best first, without duplicates.
    static func names(for context: PlaceContext) -> [String] {
        let below = context.below
        let here = shortName(below, nearbyWithin: 5_000)
        let there = context.viewCenter.flatMap(aheadName)
        let lookingElsewhere = there != nil && there != here

        var names: [String] = []
        if lookingElsewhere, let there {
            names.append(here.map { "Over \($0), looking toward \(there)" } ?? "Looking toward \(there)")
        }
        names.append(description(of: context))
        if lookingElsewhere, let center = context.viewCenter, let there, center.ahead != nil {
            let fromCamera = (center.bearing + 180).truncatingRemainder(dividingBy: 360)
            names.append("\(there) from the \(directionWord(fromCamera))")
        }
        if isPlace(below), let here { names.append(here) }
        if below.urbanArea == nil, let near = below.nearby.first {
            names.append(relativePhrase(near))
        }
        if let state = below.state {
            names.append(stateName(state))
        } else if let water = below.waters.first {
            names.append("Over \(waterName(water))")
        }

        var seen = Set<String>()
        return names.map(capitalizedFirst).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Where the camera is: "30,000 ft over Worcester", "30,000 ft, 40 mi W
    /// of Boston", "6 mi over the Gulf of Maine".
    static func description(of context: PlaceContext) -> String {
        let altitude = altitudePhrase(context.camera.height)
        let location = locationPhrase(context.below)
        return location.hasPrefix("over ") ? "\(altitude) \(location)" : "\(altitude), \(location)"
    }

    /// Where a point is, for the description: "over Worcester", "40 mi W of
    /// Boston", "over Nevada", "over the Gulf of Maine", or coordinates. The
    /// first of these that applies.
    static func locationPhrase(_ s: PlaceContext.Surroundings) -> String {
        if let urban = s.urbanArea { return "over \(urban.name)" }
        if let near = s.nearby.first { return relativePhrase(near) }
        if let state = s.state { return "over \(stateName(state))" }
        if let water = s.waters.first { return "over \(waterName(water))" }
        return "over \(coordinatePhrase(latitude: s.latitude, longitude: s.longitude))"
    }

    // MARK: Pieces

    /// The shortest name for a point: its urban area, a place within
    /// `nearbyWithin` meters, its state, or its water.
    static func shortName(_ s: PlaceContext.Surroundings, nearbyWithin: Double) -> String? {
        if let urban = s.urbanArea { return urban.name }
        if let near = s.nearby.first, near.distance <= nearbyWithin { return near.place.name }
        if let state = s.state { return stateName(state) }
        return s.waters.first.map(waterName)
    }

    /// What the camera looks toward: the place ahead, or else the view
    /// center's state or water.
    static func aheadName(_ center: PlaceContext.ViewCenter) -> String? {
        if let ahead = center.ahead { return ahead.place.name }
        if let state = center.surroundings.state { return stateName(state) }
        return center.surroundings.waters.first.map(waterName)
    }

    private static func isPlace(_ s: PlaceContext.Surroundings) -> Bool {
        s.urbanArea != nil || !s.nearby.isEmpty
    }

    /// "40 mi W of Boston", or "over Boston" within about a mile of it.
    static func relativePhrase(_ near: PlaceContext.Nearby) -> String {
        let miles = near.distance / metersPerMile
        guard miles >= 1.5 else { return "over \(near.place.name)" }
        return "\(roundedMiles(miles)) mi \(directionAbbreviation(near.bearingFromPlace)) of \(near.place.name)"
    }

    /// A state's name, with its country outside the United States: "Nevada",
    /// "Entre Ríos, Argentina".
    static func stateName(_ state: PlaceContext.Region) -> String {
        let name = qualifiedStateName(state)
        guard let country = state.country, state.countryCode != "US" else { return name }
        return "\(name), \(country)"
    }

    /// A state's name, qualified when a city in the same country has the same
    /// name: "New York State", "Osaka Prefecture", "Málaga region".
    /// Otherwise just the name.
    ///
    /// About a quarter of Natural Earth's states and provinces share a name
    /// with a city, and without a qualifier "over Málaga" reads as the city.
    /// Tradeoffs of this approach:
    /// - Natural Earth's type is used only when it's one of
    ///   `qualifyingTypes`, all single English words. It's unreliable
    ///   elsewhere: Spain's provinces are all labeled "Autonomous Community"
    ///   (the level above), Leicestershire's type is "Kingdom", and some are
    ///   compound ("Municipality|Governarate"). Those get "region", which is
    ///   vague but never wrong.
    /// - A trusted type is wrong where Natural Earth mislabels a state with
    ///   one; this hasn't been checked country by country.
    /// - Units that are themselves cities (types containing "City") keep the
    ///   bare name: the unit and the city are the same place.
    /// - It's always "<name> <Type>", idiomatic for "Osaka Prefecture" and
    ///   "New York State", passable where English says "Province of Málaga"
    ///   or "County Durham".
    /// - It applies whether or not the city is nearby, so a name doesn't
    ///   change as the camera moves.
    static func qualifiedStateName(_ state: PlaceContext.Region) -> String {
        guard state.sharesNameWithPlace else { return state.name }
        let kind = state.kind ?? ""
        if kind.contains("City") { return state.name }
        return qualifyingTypes.contains(kind) ? "\(state.name) \(kind)" : "\(state.name) region"
    }

    private static let qualifyingTypes: Set<String> = [
        "Province", "Region", "District", "Department", "County", "Prefecture", "Governorate",
        "State", "Canton", "Division", "Oblast", "Krai", "Emirate", "Voivodeship",
    ]

    /// A water's name with "the" where English uses it: "the Gulf of Maine",
    /// "the North Atlantic Ocean", "the Bosporus", but "Chesapeake Bay" and
    /// "Long Island Sound".
    static func waterName(_ water: PlaceContext.Region) -> String {
        let name = water.name
        if name.lowercased().hasPrefix("the ") { return name }
        let takesArticle: Set<String> = ["ocean", "sea", "strait", "channel", "gulf", "reef", "passage"]
        if name.contains(" of ") || takesArticle.contains(water.kind?.lowercased() ?? "") {
            return "the \(name)"
        }
        return name
    }

    /// Rounded to a friendly figure: "800 ft", "4,500 ft", "30,000 ft",
    /// then miles from about 11 miles up: "12 mi", "250 mi".
    static func altitudePhrase(_ meters: Double) -> String {
        let feet = max(meters, 0) / 0.3048
        if feet < 1_000 { return "\(grouped(max(100, rounded(feet, to: 100)))) ft" }
        if feet < 10_000 { return "\(grouped(rounded(feet, to: 500))) ft" }
        if feet < 60_000 { return "\(grouped(rounded(feet, to: 1_000))) ft" }
        let miles = meters / metersPerMile
        return "\(grouped(miles < 100 ? Int(miles.rounded()) : roundedMiles(miles))) mi"
    }

    static func coordinatePhrase(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f° %@, %.2f° %@",
               abs(latitude), latitude >= 0 ? "N" : "S", abs(longitude), longitude >= 0 ? "E" : "W")
    }

    private static let metersPerMile = 1_609.344

    private static func roundedMiles(_ miles: Double) -> Int {
        if miles < 10 { return max(1, Int(miles.rounded())) }
        if miles < 100 { return rounded(miles, to: 5) }
        if miles < 1_000 { return rounded(miles, to: 10) }
        return rounded(miles, to: 50)
    }

    private static func rounded(_ value: Double, to step: Int) -> Int {
        Int((value / Double(step)).rounded()) * step
    }

    private static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private static let abbreviations = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    private static let words = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]

    private static func octant(_ degrees: Double) -> Int {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return Int(((d < 0 ? d + 360 : d) / 45).rounded()) % 8
    }

    static func directionAbbreviation(_ degrees: Double) -> String { abbreviations[octant(degrees)] }
    static func directionWord(_ degrees: Double) -> String { words[octant(degrees)] }

    private static func capitalizedFirst(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }
}
