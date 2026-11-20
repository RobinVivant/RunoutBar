import Testing
@testable import RunoutCore

@Suite struct SeriesTests {
    private func line(_ pairs: (Double, Double)...) -> [Series.Point] { pairs.map { Series.Point(x: $0.0, y: $0.1) } }

    @Test func interpolatesBetweenPointsAndStopsAtTheEnds() {
        let points = line((10, 20), (20, 40), (40, 40))
        #expect(Series.interpolate(points, at: 15) == 30)
        #expect(Series.interpolate(points, at: 10) == 20)
        #expect(Series.interpolate(points, at: 40) == 40)
        #expect(Series.interpolate(points, at: 30) == 40)
        #expect(Series.interpolate(points, at: 9.9) == nil)
        #expect(Series.interpolate(points, at: 40.1) == nil)
        #expect(Series.interpolate([], at: 1) == nil)
        #expect(Series.interpolate(line((5, 7)), at: 5) == 7)
    }

    @Test func aSteppedLineHoldsItsLastValue() {
        let points = line((10, 20), (20, 40), (40, 45))
        #expect(Series.held(points, at: 19.9) == Series.Point(x: 10, y: 20))
        #expect(Series.held(points, at: 20) == Series.Point(x: 20, y: 40))
        #expect(Series.held(points, at: 500) == Series.Point(x: 40, y: 45))
        #expect(Series.held(points, at: 9) == nil)
    }

    @Test func nearestPicksTheClosestPointOnEitherSide() {
        let points = line((10, 20), (20, 40), (40, 45))
        #expect(Series.nearest(points, to: 14) == Series.Point(x: 10, y: 20))
        #expect(Series.nearest(points, to: 16) == Series.Point(x: 20, y: 40))
        #expect(Series.nearest(points, to: -3) == Series.Point(x: 10, y: 20))
        #expect(Series.nearest(points, to: 90) == Series.Point(x: 40, y: 45))
        #expect(Series.nearest([], to: 1) == nil)
    }

    @Test func closestIsTheLineNearestThePointerWithinReach() throws {
        let low = line((0, 0), (100, 20))
        let high = line((0, 50), (50, 70))
        let nearLow = try #require(Series.closest([low, high], x: 50, y: 18, reach: 10))
        #expect(nearLow.index == 0)
        #expect(nearLow.y == 10)
        let nearHigh = try #require(Series.closest([low, high], x: 25, y: 55, reach: 10))
        #expect(nearHigh.index == 1)
        #expect(nearHigh.y == 60)
        // Halfway between the two, neither is within reach.
        #expect(Series.closest([low, high], x: 50, y: 40, reach: 10) == nil)
        // Past the end of the high line only the low one can answer.
        #expect(Series.closest([low, high], x: 80, y: 60, reach: 50)?.index == 0)
        #expect(Series.closest([], x: 1, y: 1, reach: 10) == nil)
    }

    @Test func sinceLastResetTrimsDropSpikesButKeepsSmallWobble() {
        let steady = line((0, 10), (20, 20), (25, 19), (40, 30))
        let untrimmed = Series.sinceLastReset(steady)
        #expect(!untrimmed.reset)
        #expect(untrimmed.points == steady)

        let oneReset = line((0, 10), (20, 95), (20.1, 0), (30, 12))
        let afterOne = Series.sinceLastReset(oneReset)
        #expect(afterOne.reset)
        #expect(afterOne.points == line((20.1, 0), (30, 12)))

        let twoResets = line((0, 10), (20, 98), (21, 5), (50, 98), (51, 2), (60, 14))
        let afterTwo = Series.sinceLastReset(twoResets)
        #expect(afterTwo.reset)
        #expect(afterTwo.points == line((51, 2), (60, 14)))

        #expect(Series.sinceLastReset([]).points.isEmpty)
        #expect(!Series.sinceLastReset(line((0, 5))).reset)
    }
}
