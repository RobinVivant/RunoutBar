import Foundation

/// Lookups on a chart line, for the readout under the pointer. Points are in ascending x.
public enum Series {
    public struct Point: Sendable, Hashable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// The line's y at `x`, straight between its points; nil outside its span.
    public static func interpolate(_ points: [Point], at x: Double) -> Double? {
        guard let first = points.first, let last = points.last, x >= first.x, x <= last.x else { return nil }
        guard let after = points.firstIndex(where: { $0.x >= x }), after > 0 else { return first.y }
        let (a, b) = (points[after - 1], points[after])
        return b.x > a.x ? a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x) : b.y
    }

    /// The last point at or before `x`, which is what a stepped line shows there; nil before the first point.
    public static func held(_ points: [Point], at x: Double) -> Point? {
        points.last { $0.x <= x }
    }

    /// The point closest to `x`, on either side.
    public static func nearest(_ points: [Point], to x: Double) -> Point? {
        points.min { abs($0.x - x) < abs($1.x - x) }
    }

    /// The line that passes closest above or below (x, y), with its y there; nil when none comes within `reach`.
    public static func closest(_ lines: [[Point]], x: Double, y: Double, reach: Double) -> (index: Int, y: Double)? {
        var best: (index: Int, y: Double)?
        for (index, line) in lines.enumerated() {
            guard let value = interpolate(line, at: x), abs(value - y) <= reach else { continue }
            if best.map({ abs(value - y) < abs($0.y - y) }) ?? true { best = (index, value) }
        }
        return best
    }
}
