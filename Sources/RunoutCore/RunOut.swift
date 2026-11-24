import Foundation

/// When a capacity lane runs out against the end of the work week.
///
/// The lane runs out when every account's weekly window in that lane reaches its threshold
/// (TeamClaude's switch threshold for pooled Claude accounts, 100% for direct CLIs).
/// Usage counts in percentage points of an account. Pace prefers recency over the last two
/// workdays so mid-week model switches reflect promptly without oscillating on single prompts.
public struct PoolRunOut: Sendable, Hashable {
    public enum State: String, Sendable {
        /// No measurable burn in the pace window and not exhausted.
        case idle
        /// Active burn, projected to last until the target.
        case lasts
        /// Projected to run out before the target.
        case short
        /// Out now, or runs out today before the target.
        case critical
    }

    public enum PaceBasis: String, Sendable, Hashable {
        case twoWorkdays = "last 2 workdays"
        case recencyWeighted = "2-day recency"
        case activeToday = "active today"
    }

    /// When every account in the lane reaches the threshold; nil when later than a week past the target or idle.
    public var at: Date?
    /// The end of the work week.
    public var target: Date
    /// Points of the lane used per work hour.
    public var ratePerWorkHour: Double
    /// Work time the pace was measured over.
    public var measuredOver: TimeInterval
    /// The highest pace that still lasts until the target; nil when the lane is out now.
    public var budgetPerWorkHour: Double?
    public var state: State
    public var paceBasis: PaceBasis
    /// Burned in the prior workday, flat for at least 4 work hours today.
    public var quietToday: Bool

    /// How long after the target the lane runs out; negative when it runs out first.
    public var margin: TimeInterval? { at.map { $0.timeIntervalSince(target) } }

    /// Current pace divided by sustainable work-week budget (below 1.0 lasts, above 1.0 runs short).
    public var paceRatio: Double? {
        guard let budget = budgetPerWorkHour, budget > 1e-6 else { return nil }
        return ratePerWorkHour / budget
    }

    /// Workdays of History the pace is measured over.
    public static let paceWorkdays = 2.0
    /// A drop in a reading larger than this, in points, is a reset rather than noise.
    static let resetDrop = 2.0
    /// Less measured work time than this gives no pace.
    public static let minimumMeasured: TimeInterval = 2 * 3600

    public init(at: Date?, target: Date, ratePerWorkHour: Double, measuredOver: TimeInterval,
                budgetPerWorkHour: Double?, state: State, paceBasis: PaceBasis = .twoWorkdays,
                quietToday: Bool = false) {
        self.at = at
        self.target = target
        self.ratePerWorkHour = ratePerWorkHour
        self.measuredOver = measuredOver
        self.budgetPerWorkHour = budgetPerWorkHour
        self.state = state
        self.paceBasis = paceBasis
        self.quietToday = quietToday
    }

    /// The run-out time worth printing in the menu bar: before the target, or within six days so the
    /// weekday names a single day. Nil means it lasts well past the target or is idle.
    public func shownDate(now: Date) -> Date? {
        guard let at else { return nil }
        return at < target || at.timeIntervalSince(now) < 6 * 86_400 ? at : nil
    }

    /// One account's weekly window.
    struct Slot {
        var account: String
        var window: String
        var used: Double
        var reset: Date
        var duration: TimeInterval
        var untouched: Bool
    }

    /// Projects run-out for the Claude pool from a mixed account list.
    public static func make(accounts: [AccountSnapshot], history: History, now: Date, threshold: Double = Levels.full,
                            week: WorkWeek, calendar: Calendar = .current) -> PoolRunOut? {
        let claude = accounts.filter { $0.provider == .claude }
        guard !claude.isEmpty else { return nil }
        let lane = CapacityLane(id: "claude", provider: .claude, title: "Claude",
                                kind: .pooled(proxy: "TeamClaude", switchThreshold: threshold),
                                accounts: claude, threshold: threshold)
        return make(lane: lane, history: history, now: now, week: week, calendar: calendar)
    }

    /// Projects run-out for any capacity lane (`Claude` pool, `Codex`, or a Google AI group).
    /// Nil unless every account in the lane has a fresh weekly reading and enough work history (or is untouched).
    public static func make(lane: CapacityLane, history: History, now: Date, week: WorkWeek,
                            calendar: Calendar = .current) -> PoolRunOut? {
        guard !lane.accounts.isEmpty, let target = week.weekEnd(after: now, calendar: calendar) else { return nil }
        let threshold = lane.threshold
        var slots: [Slot] = []
        for account in lane.accounts {
            guard !account.isStale(at: now), let weekly = account.weekly, let used = weekly.used,
                  let duration = weekly.duration, duration > 0 else { return nil }
            let untouched = weekly.resetsAt == nil && used == 0
            guard var reset = weekly.resetsAt ?? (untouched ? now.addingTimeInterval(duration) : nil) else {
                return nil
            }
            while reset <= now { reset.addTimeInterval(duration) }  // a reset the proxy has not caught up with
            slots.append(Slot(account: account.id, window: weekly.id, used: used, reset: reset,
                              duration: duration, untouched: untouched))
        }

        let budget = budget(slots, now: now, target: target, threshold: threshold, week: week, calendar: calendar)
        if let result = pace(slots, history: history, now: now, week: week, calendar: calendar) {
            if !slots.allSatisfy({ $0.used >= threshold }) && result.rate < 0.05 && result.totalUsed < 0.5 {
                return PoolRunOut(at: nil, target: target, ratePerWorkHour: 0, measuredOver: result.measured,
                                  budgetPerWorkHour: budget, state: .idle, paceBasis: result.basis,
                                  quietToday: result.quietToday)
            }
            let horizon = target.addingTimeInterval(7 * 86_400)
            let at = project(slots, rate: result.rate, now: now, horizon: horizon, threshold: threshold, week: week,
                             calendar: calendar)
            let state: State
            if let at, at < target {
                state = at <= now || calendar.isDate(at, inSameDayAs: now) ? .critical : .short
            } else {
                state = .lasts
            }
            return PoolRunOut(at: at, target: target, ratePerWorkHour: result.rate, measuredOver: result.measured,
                              budgetPerWorkHour: budget, state: state, paceBasis: result.basis,
                              quietToday: result.quietToday)
        }

        // An untouched lane ("starts on first use") is known idle even before 2 work hours of history accumulate.
        if slots.allSatisfy(\.untouched) {
            return PoolRunOut(at: nil, target: target, ratePerWorkHour: 0, measuredOver: 0,
                              budgetPerWorkHour: budget, state: .idle, paceBasis: .twoWorkdays, quietToday: false)
        }
        return nil
    }

    struct PaceResult {
        var rate: Double
        var measured: TimeInterval
        var totalUsed: Double
        var basis: PaceBasis
        var quietToday: Bool
    }

    /// Points per work hour across the slots' windows over the last `paceWorkdays`.
    /// When at least `minimumMeasured` work hours exist both today and prior to today, blends
    /// today's rate (65%) with prior workday rate (35%), or uses today's rate alone for a freshly
    /// activated lane that was flat in the prior workday.
    static func pace(_ slots: [Slot], history: History, now: Date, week: WorkWeek,
                     calendar: Calendar) -> PaceResult? {
        let since = week.date(subtractingWork: paceWorkdays * week.hoursPerDay * 3600, from: now, calendar: calendar,
                              limit: now.addingTimeInterval(-History.retention))
        let todayStart = calendar.startOfDay(for: now)
        let todayWork = week.workTime(from: todayStart, to: now, calendar: calendar)
        let prevShiftEnd = week.previousWorkdayEnd(before: now, calendar: calendar)

        var earliest: Date?
        var totalUsed = 0.0
        var usedBefore = 0.0
        var usedRecent = 0.0

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
                var delta = 0.0
                if point.value > level {
                    delta = point.value - level
                    level = point.value
                } else if level - point.value > resetDrop {
                    delta = point.value
                    level = point.value
                }
                guard delta > 0 else { continue }
                totalUsed += delta
                if let split = prevShiftEnd {
                    if point.time <= split {
                        usedBefore += delta
                    } else {
                        usedRecent += delta
                    }
                }
            }
        }
        guard let earliest else { return nil }
        let totalMeasured = week.workTime(from: earliest, to: now, calendar: calendar)
        guard totalMeasured >= minimumMeasured else { return nil }

        let priorWork = prevShiftEnd.map { week.workTime(from: earliest, to: $0, calendar: calendar) } ?? 0
        if todayWork >= minimumMeasured, priorWork >= minimumMeasured {
            let priorRate = usedBefore / (priorWork / 3600)
            let recentRate = usedRecent / (todayWork / 3600)
            if usedBefore < 1.0 && usedRecent >= 2.0 {
                return PaceResult(rate: recentRate, measured: todayWork, totalUsed: usedRecent,
                                  basis: .activeToday, quietToday: false)
            }
            let weighted = 0.65 * recentRate + 0.35 * priorRate
            let quiet = usedBefore >= 1.0 && usedRecent < 0.5 && todayWork >= 4 * 3600
            return PaceResult(rate: weighted, measured: totalMeasured, totalUsed: totalUsed,
                              basis: .recencyWeighted, quietToday: quiet)
        }
        return PaceResult(rate: totalUsed / (totalMeasured / 3600), measured: totalMeasured,
                          totalUsed: totalUsed, basis: .twoWorkdays, quietToday: false)
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
