import Foundation
import Testing
import simd

private let perMetre = 180 / (.pi * GeoMath.earthRadius)

private func route(_ lines: [[(north: Double, heartRate: Double?)]]) -> ImportedRoute {
    let document = RouteDocument(name: nil, lines: lines.map { line in
        .init(track: 0, points: line.map {
            RouteDocument.Point(latitude: 37 + $0.north * perMetre, longitude: -122, heartRate: $0.heartRate)
        })
    }, heightDatum: .meanSeaLevel)
    return ImportedRoute(document: document)!
}

private func geometry(_ route: ImportedRoute, _ scale: RouteColourScale?) -> RouteGeometry {
    let heights = route.heights(mode: .recorded, surface: [])
    return RouteGeometry(route: route, positions: route.positions(heights: heights),
                         values: RouteColouring.heartRate.values(route), scale: scale, liftsByRadius: false)
}

struct RouteColourScaleTests {
    @Test func binsAreEvenBetweenTheEnds() {
        let scale = RouteColourScale(lower: 100, upper: 180)
        #expect(scale.bin(100) == 0)
        #expect(scale.bin(109.9) == 0)
        #expect(scale.bin(110) == 1)
        #expect(scale.bin(179.9) == RouteColourScale.binCount - 1)
        #expect(scale.range(ofBin: 1) == 110...120)
    }

    @Test func valuesBeyondTheEndsTakeTheEndColourAndMissingOnesTheirOwn() {
        let scale = RouteColourScale(lower: 100, upper: 180)
        #expect(scale.bin(20) == 0)
        #expect(scale.bin(500) == RouteColourScale.binCount - 1)
        #expect(scale.bin(nil) == RouteColourScale.noDataBin)
        #expect(scale.bin(.nan) == RouteColourScale.noDataBin)
    }

    @Test func outliersDontStretchTheScale() throws {
        // 1…100, plus one wild reading.
        let values: [Double?] = (1...100).map(Double.init) + [10_000, nil]
        let scale = try #require(RouteColourScale(values: values, minimumSpan: 1))
        #expect(scale.lower == 6)
        #expect(scale.upper == 96)
    }

    @Test func aNarrowRangeIsWidenedAboutItsMiddle() throws {
        let scale = try #require(RouteColourScale(values: [140, 141, 142], minimumSpan: 10))
        #expect(scale.lower == 136 && scale.upper == 146)
        #expect(RouteColourScale(values: [nil, nil], minimumSpan: 1) == nil)
    }

    @Test func everyColourHasAnEntry() {
        #expect(RouteColourScale.colours.count == RouteColourScale.colourCount)
    }
}

struct RouteGeometryTests {
    @Test func runsSplitWhereTheColourChangesAndShareThatPoint() {
        // Heart rate 100, 100, 180, 180: the middle step averages 140.
        let r = route([[(0, 100), (10, 100), (20, 180), (30, 180)]])
        let g = geometry(r, RouteColourScale(lower: 100, upper: 180))
        #expect(g.runs.map(\.bin) == [0, 4, 7])
        #expect(g.runs.map(\.points.count) == [2, 2, 2])
        #expect(g.runs[0].points.last == g.runs[1].points.first)
        #expect(g.runs[0].points.first == .zero)  // Relative to the first point.
    }

    @Test func runsDontCrossSegments() {
        let r = route([[(0, 100), (10, 100)], [(100, 100), (110, 100)]])
        let g = geometry(r, RouteColourScale(lower: 100, upper: 180))
        #expect(g.runs.count == 2)
        #expect(g.runs.allSatisfy { $0.points.count == 2 })
    }

    @Test func aStepWithOneValueTakesItAndWithNoneIsNoData() {
        let r = route([[(0, 100), (10, nil), (20, nil)]])
        let g = geometry(r, RouteColourScale(lower: 100, upper: 180))
        #expect(g.runs.map(\.bin) == [0, RouteColourScale.noDataBin])
    }

    @Test func noScaleIsOnePlainRunPerSegment() {
        let r = route([[(0, 100), (10, 180), (20, 100)]])
        let g = geometry(r, nil)
        #expect(g.runs.map(\.bin) == [RouteColourScale.plainBin])
        #expect(g.runs[0].points.count == 3)
    }

    @Test func simplificationKeepsEachRunsEnds() {
        let r = route([[(0, 100), (10, 100), (20, 100), (30, 100)]])
        let g = geometry(r, RouteColourScale(lower: 100, upper: 180))
        // A straight line: only its ends survive any tolerance.
        #expect(g.runs[0].points(tolerance: 0.1).count == 2)
    }

    @Test func colouringIsOnlyOfferedWhenTheRouteHasValues() {
        let r = route([[(0, nil), (10, nil)]])
        #expect(!RouteColouring.heartRate.isAvailable(for: r))
        #expect(!RouteColouring.speed.isAvailable(for: r))  // No times.
        #expect(RouteColouring.plain.isAvailable(for: r))
    }
}
