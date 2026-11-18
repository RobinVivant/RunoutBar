import Foundation

/// The days and hours of work. Pool usage is measured and projected over this time only, so
/// nights and weekends neither dilute the pace nor burn capacity in the projection.
///
/// In config.json: `{"days": ["Mon", "Tue", "Wed", "Thu", "Fri"], "start": "09:00", "end": "19:00"}`.
public struct WorkWeek: Sendable, Hashable {
    /// `Calendar` weekday numbers: 1 is Sunday, 2 is Monday.
    public var days: Set<Int>
    /// Minutes after local midnight, `start < end <= 1440`.
    public var start: Int
    public var end: Int

    public init(days: Set<Int> = [2, 3, 4, 5, 6], start: Int = 9 * 60, end: Int = 19 * 60) {
        self.days = days
        self.start = start
        self.end = end
    }

    public var hoursPerDay: Double { Double(max(0, end - start)) / 60 }

    /// The work interval on the day that contains `day`, if it is a workday.
    func shift(on day: Date, calendar: Calendar) -> DateInterval? {
        guard end > start, days.contains(calendar.component(.weekday, from: day)) else { return nil }
        guard let from = calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: day),
              let to = end >= 1440
                ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
                : calendar.date(bySettingHour: end / 60, minute: end % 60, second: 0, of: day),
              to > from else { return nil }
        return DateInterval(start: from, end: to)
    }

    private func days(from date: Date, step: Int, calendar: Calendar) -> some Sequence<Date> {
        sequence(first: calendar.startOfDay(for: date)) { calendar.date(byAdding: .day, value: step, to: $0) }
    }

    /// Work time between two instants.
    public func workTime(from: Date, to: Date, calendar: Calendar = .current) -> TimeInterval {
        guard to > from else { return 0 }
        var total: TimeInterval = 0
        for day in days(from: from, step: 1, calendar: calendar) {
            guard day < to else { break }
            guard let shift = shift(on: day, calendar: calendar) else { continue }
            let overlap = min(shift.end, to).timeIntervalSince(max(shift.start, from))
            if overlap > 0 { total += overlap }
        }
        return total
    }

    /// The instant `work` seconds of work time after `date`, or nil when that is later than `limit`.
    public func date(addingWork work: TimeInterval, to date: Date, calendar: Calendar = .current,
                     limit: Date) -> Date? {
        guard work > 0 else { return date }
        var left = work
        for day in days(from: date, step: 1, calendar: calendar) {
            guard day < limit else { break }
            guard let shift = shift(on: day, calendar: calendar), shift.end > date else { continue }
            let from = max(shift.start, date)
            let available = shift.end.timeIntervalSince(from)
            if available >= left {
                let result = from.addingTimeInterval(left)
                return result <= limit ? result : nil
            }
            left -= available
        }
        return nil
    }

    /// The instant `work` seconds of work time before `date`, or `limit` when there is less work time in between.
    public func date(subtractingWork work: TimeInterval, from date: Date, calendar: Calendar = .current,
                     limit: Date) -> Date {
        guard work > 0 else { return date }
        var left = work
        for day in days(from: date, step: -1, calendar: calendar) {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > limit else { break }
            guard let shift = shift(on: day, calendar: calendar) else { continue }
            let from = max(shift.start, limit), to = min(shift.end, date)
            guard to > from else { continue }
            let available = to.timeIntervalSince(from)
            if available >= left { return to.addingTimeInterval(-left) }
            left -= available
        }
        return limit
    }

    /// "Mon–Fri 09:00–19:00", or the days listed when they are not a run.
    public var summary: String {
        let order = days.map { ($0 + 5) % 7 }.sorted()  // Monday is 0
        let name = { (index: Int) in Self.dayNames[(index + 1) % 7].capitalized }
        let run = order.count > 2 && order.last! - order.first! == order.count - 1
        let dayText = run ? "\(name(order.first!))–\(name(order.last!))" : order.map(name).joined(separator: ", ")
        return dayText + String(format: " %02d:%02d–%02d:%02d", start / 60, start % 60, end / 60, end % 60)
    }

    /// The last workday of the week, counting from Monday.
    var lastDay: Int? { days.max { ($0 + 5) % 7 < ($1 + 5) % 7 } }

    /// The end of the week's last workday (Friday 19:00 by default): this week's while it is ahead,
    /// then next week's.
    public func weekEnd(after now: Date, calendar: Calendar = .current) -> Date? {
        guard let lastDay else { return nil }
        for day in days(from: now, step: 1, calendar: calendar).prefix(8) {
            if calendar.component(.weekday, from: day) == lastDay, let shift = shift(on: day, calendar: calendar),
               shift.end > now {
                return shift.end
            }
        }
        return nil
    }
}

extension WorkWeek: Codable {
    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    enum CodingKeys: String, CodingKey { case days, start, end }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WorkWeek()
        if let names = try c.decodeIfPresent([String].self, forKey: .days) {
            days = Set(try names.map { name in
                guard let index = Self.dayNames.firstIndex(of: String(name.lowercased().prefix(3))) else {
                    throw DecodingError.dataCorruptedError(forKey: .days, in: c,
                                                           debugDescription: "Unknown day \"\(name)\"; use Mon to Sun")
                }
                return index + 1
            })
        } else {
            days = defaults.days
        }
        start = try Self.minutes(c, .start) ?? defaults.start
        end = try Self.minutes(c, .end) ?? defaults.end
        guard start < end else {
            throw DecodingError.dataCorruptedError(forKey: .end, in: c, debugDescription: "end must be after start")
        }
    }

    /// "09:30" as minutes after midnight; "24:00" is allowed as an end.
    private static func minutes(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Int? {
        guard let text = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        let parts = text.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let hour = parts[0], let minute = parts[1], (0...59).contains(minute),
              (0...23).contains(hour) || (hour == 24 && minute == 0) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Use HH:mm, not \"\(text)\"")
        }
        return hour * 60 + minute
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { Self.dayNames[$0 - 1].capitalized },
                     forKey: .days)
        try c.encode(String(format: "%02d:%02d", start / 60, start % 60), forKey: .start)
        try c.encode(String(format: "%02d:%02d", end / 60, end % 60), forKey: .end)
    }
}
