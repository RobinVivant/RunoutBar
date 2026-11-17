import Foundation

/// When the Claude pool as a whole runs out, against the end of the work week.
///
/// The pool runs out when every Claude account's weekly window is at the threshold. Usage counts
/// in percentage points of an account (each account holds 0 to 100, so accounts are treated as
/// the same size). The pace is points per work hour, measured from History over the last two
/// workdays: everything used in that span, nights included, divided by its work time. The
/// projection burns at that pace during work hours only, drains the account whose week resets
/// first, and gives each account its capacity back at its own reset.
public struct PoolRunOut: Sendable, Hashable {
    public enum State: String, Sendable {
        /// The pool lasts until the target.
        case lasts
        /// It runs out before the target.
        case short
        /// It is out now, or runs out today before the target.
        case critical
    }

    /// When every Claude account reaches the threshold; nil when that is later than a week past the target.
    public var at: Date?
    /// The end of the work week.
    public var target: Date
    /// Points of the pool used per work hour.
    public var ratePerWorkHour: Double
    /// Work time the pace was measured over.
    public var measuredOver: TimeInterval
    /// The highest pace that still lasts until the target; nil when the pool is out now.
    public var budgetPerWorkHour: Double?
    public var state: State

    /// How long after the target the pool runs out; negative when it runs out first.
    public var margin: TimeInterval? { at.map { $0.timeIntervalSince(target) } }

    /// Workdays of History the pace is measured over.
    public static let paceWorkdays = 2.0
    /// A drop in a reading larger than this, in points, is a reset rather than noise.
    static let resetDrop = 2.0
    /// Less measured work time than this gives no pace.
    public static let minimumMeasured: TimeInterval = 2 * 3600

    /// The run-out time worth printing in the menu bar: before the target, or within six days so the
    /// weekday names a single day. Nil means it lasts well past the target.
    public func shownDate(now: Date) -> Date? {
        guard let at else { return nil }
        return at < target || at.timeIntervalSince(now) < 6 * 86_400 ? at : nil
    }

    /// One Claude account's weekly window.
    struct Slot {
        var account: String
        var window: String
        var used: Double
        var reset: Date
        var duration: TimeInterval
    }

    /// Nil unless every Claude account has a fresh weekly reading and History holds enough work time.
    public static func make(accounts: [AccountSnapshot], history: History, now: Date, threshold: Double = Levels.full,
                            week: WorkWeek, calendar: Calendar = .current) -> PoolRunOut? {
        let claude = accounts.filter { $0.provider == .claude }
        guard !claude.isEmpty, let target = week.weekEnd(after: now, calendar: calendar) else { return nil }
        var slots: [Slot] = []
        for account in claude {
            guard !account.isStale(at: now), let weekly = account.weekly, let used = weekly.used,
                  var reset = weekly.resetsAt, let duration = weekly.duration, duration > 0 else { return nil }
            while reset <= now { reset.addTimeInterval(duration) }  // a reset the proxy has not caught up with
            slots.append(Slot(account: account.id, window: weekly.id, used: used, reset: reset, duration: duration))
        }
        guard let (rate, measured) = pace(slots, history: history, now: now, week: week, calendar: calendar) else {
            return nil
        }

        let horizon = target.addingTimeInterval(7 * 86_400)
        let at = project(slots, rate: rate, now: now, horizon: horizon, threshold: threshold, week: week,
                         calendar: calendar)
        let state: State
        if let at, at < target {
            state = at <= now || calendar.isDate(at, inSameDayAs: now) ? .critical : .short
        } else {
            state = .lasts
        }
        let budget = budget(slots, now: now, target: target, threshold: threshold, week: week, calendar: calendar)
        return PoolRunOut(at: at, target: target, ratePerWorkHour: rate, measuredOver: measured,
                          budgetPerWorkHour: budget, state: state)
    }

    /// Points per work hour across the slots' windows over the last `paceWorkdays`, and the work time measured.
    static func pace(_ slots: [Slot], history: History, now: Date, week: WorkWeek,
                     calendar: Calendar) -> (rate: Double, measured: TimeInterval)? {
        let since = week.date(subtractingWork: paceWorkdays * week.hoursPerDay * 3600, from: now, calendar: calendar,
                              limit: now.addingTimeInterval(-History.retention))
        var earliest: Date?
        var used = 0.0
        for slot in slots {
            var points = history.samples(slot.account)
                .filter { $0.time >= since && $0.time <= now }
                .compactMap { sample in sample.values[slot.window].map { (time: sample.time, value: $0) } }
            if points.last.map({ $0.time < now }) ?? true { points.append((now, slot.used)) }
            guard points.count > 1 else { continue }
            earliest = min(earliest ?? points[0].time, points[0].time)
            // Readings wobble by a point around a rounding edge (50, 49, 50), so usage is the rise of the
            // highest value seen. A larger drop is a reset: the window started again from zero.
            var level = points[0].value
            for point in points.dropFirst() {
                if point.value > level {
                    used += point.value - level
                    level = point.value
                } else if level - point.value > resetDrop {
                    used += point.value
                    level = point.value
                }
            }
        }
        guard let earliest else { return nil }
        let measured = week.workTime(from: earliest, to: now, calendar: calendar)
        guard measured >= minimumMeasured else { return nil }
        return (used / (measured / 3600), measured)
    }

    /// When every slot reaches the threshold at `rate` points per work hour, or nil if not by `horizon`.
    static func project(_ slots: [Slot], rate: Double, now: Date, horizon: Date, threshold: Double, week: WorkWeek,
                        calendar: Calendar) -> Date? {
        var slots = slots
        var time = now
        while true {
            if slots.allSatisfy({ $0.used >= threshold }) { return time }
            guard time < horizon, let nextReset = slots.map(\.reset).min() else { return nil }
            let until = min(nextReset, horizon)
            // Drain the open account whose week ends first, so the least capacity expires unused.
            let open = slots.indices.filter { slots[$0].used < threshold }
            if rate > 0, let index = open.min(by: { slots[$0].reset < slots[$1].reset }) {
                let needed = (threshold - slots[index].used) / rate * 3600
                if let full = week.date(addingWork: needed, to: time, calendar: calendar, limit: until) {
                    slots[index].used = threshold
                    time = full
                    continue
                }
                slots[index].used += week.workTime(from: time, to: until, calendar: calendar) / 3600 * rate
            }
            time = until
            for index in slots.indices where slots[index].reset <= time {
                slots[index].used = 0
                slots[index].reset.addTimeInterval(slots[index].duration)
            }
        }
    }

    /// The highest rate whose projection still reaches the target, by bisection.
    static func budget(_ slots: [Slot], now: Date, target: Date, threshold: Double, week: WorkWeek,
                       calendar: Calendar) -> Double? {
        func lasts(_ rate: Double) -> Bool {
            project(slots, rate: rate, now: now, horizon: target, threshold: threshold, week: week,
                    calendar: calendar).map { $0 >= target } ?? true
        }
        guard lasts(1e-9) else { return nil }
        var low = 0.0, high = 1.0
        for _ in 0..<40 where lasts(high) { low = high; high *= 2 }
        guard !lasts(high) else { return nil }  // no work time before the target: any pace lasts
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if lasts(mid) { low = mid } else { high = mid }
        }
        return low
    }
}
