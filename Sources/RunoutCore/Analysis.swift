import Foundation

public enum Tier: String, Codable, Sendable, Comparable {
    case ok, high, full

    public static func < (a: Tier, b: Tier) -> Bool {
        let order: [Tier] = [.ok, .high, .full]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

public enum Levels {
    public static let high: Double = 90
    /// TeamClaude's default switch threshold: the account leaves rotation.
    public static let full: Double = 98
    public static let staleAfter: TimeInterval = 180

    /// Stale cutoff for a proxy that checks usage every `probeInterval` seconds (0 means off):
    /// one missed check is tolerated, so a 5 or 10 minute interval does not grey out idle accounts.
    public static func staleAfter(probeInterval: Int) -> TimeInterval {
        probeInterval > 0 ? max(staleAfter, Double(probeInterval) * 2 + 60) : staleAfter
    }

    public static func tier(_ used: Double, full: Double = Levels.full) -> Tier {
        used >= full ? .full : used >= high ? .high : .ok
    }
}

extension AccountSnapshot {
    public func isStale(at now: Date) -> Bool {
        if error != nil { return true }
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > staleAfter
    }

    var readings: [LimitWindow] { windows.filter { $0.used != nil } }

    /// Every window has a fresh value.
    public func isKnown(at now: Date) -> Bool {
        !windows.isEmpty && readings.count == windows.count && !isStale(at: now)
    }

    /// Some windows have values, others are not reported.
    public func isPartial(at now: Date) -> Bool {
        !readings.isEmpty && readings.count < windows.count && !isStale(at: now)
    }

    /// The fullest window with a value.
    public var peakWindow: LimitWindow? { readings.max { ($0.used ?? 0) < ($1.used ?? 0) } }

    public var peak: Double? { peakWindow?.used }

    public func tier(at now: Date, full: Double = Levels.full) -> Tier? {
        guard isKnown(at: now) || isPartial(at: now), let peak else { return nil }
        return Levels.tier(peak, full: full)
    }

    /// The time the account is usable again when it is full: the latest reset
    /// among its exhausted windows.
    public func freeAgainAt(full: Double = Levels.full) -> Date? {
        let blocking = readings.filter { ($0.used ?? 0) >= full }
        guard !blocking.isEmpty, blocking.allSatisfy({ $0.resetsAt != nil }) else { return nil }
        return blocking.compactMap(\.resetsAt).max()
    }

    /// The reset that belongs beside `peak`: when a full account is usable again, otherwise the reset of
    /// the window the figure is taken from. After a banked reset the weekly window is low while the
    /// session fills within hours, and the weekly reset would then count down to the wrong thing.
    public func headlineReset(full: Double = Levels.full) -> Date? {
        freeAgainAt(full: full) ?? peakWindow?.resetsAt
    }
}

extension LimitWindow {
    /// The window's own level, for a bar that draws this window alone.
    public func tier(full: Double = Levels.full) -> Tier? {
        used.map { Levels.tier($0, full: full) }
    }
}

public struct Pace: Sendable, Hashable {
    public enum Basis: String, Sendable {
        case proxyForecast = "proxy forecast"
        case recent = "last 30 min"
        case windowAverage = "window average"
    }

    /// Where an even pace would put usage now, 0 to 100.
    public var even: Double
    /// Percent per hour, when known.
    public var ratePerHour: Double?
    public var basis: Basis?
    /// When the window reaches the threshold at this pace, if before the reset.
    public var fullAt: Date?
    /// Projected usage at the reset, capped at 100.
    public var atReset: Double

    public var fullBeforeReset: Bool { fullAt != nil }
}

public enum PaceModel {
    /// A drop larger than this, in percent points, marks a reset rather than reading wobble.
    static let resetDrop: Double = 2.0

    /// Pace for one window. Prefers the proxy's own forecast, then the measured
    /// rate over the last half hour, then the average since the window began.
    public static func pace(for window: LimitWindow, samples: [Sample], now: Date,
                            observedAt: Date? = nil, threshold: Double = Levels.full) -> Pace? {
        guard let used = window.used, let reset = window.resetsAt, let duration = window.duration,
              reset > now, let elapsed = window.elapsed(at: now) else { return nil }
        let anchor = min(now, observedAt ?? now)
        let remaining = max(0, reset.timeIntervalSince(anchor))

        var rate: Double?  // percent per second
        var basis: Pace.Basis?
        var fullAt: Date?
        if let forecast = window.forecast, let perHour = forecast.ratePerHour, perHour > 1e-6 {
            rate = perHour / 3600
            basis = .proxyForecast
            if let at = forecast.reachesThresholdAt, at > now, at < reset { fullAt = at }
        } else if let measured = recentRate(samples: samples, window: window.id, value: used, now: anchor,
                                            windowStart: window.windowStart) {
            rate = measured
            basis = .recent
        } else if let anchorElapsed = window.elapsed(at: anchor), anchorElapsed > 0.05 {
            rate = used / (anchorElapsed * duration)
            basis = .windowAverage
        }

        if fullAt == nil, let rate, rate > 0, used < threshold {
            let at = anchor.addingTimeInterval((threshold - used) / rate)
            if at > now, at < reset { fullAt = at }
        }
        let atReset = min(100, used + (rate ?? 0) * remaining)
        return Pace(even: elapsed * 100, ratePerHour: rate.map { $0 * 3600 }, basis: basis, fullAt: fullAt,
                    atReset: atReset)
    }

    /// Percent per second over roughly the last half hour, within the current window.
    static func recentRate(samples: [Sample], window: String, value: Double, now: Date,
                           windowStart: Date? = nil, lookback: TimeInterval = 1800) -> Double? {
        var earlier: (Date, Double)?
        var low = value
        for sample in samples.reversed() {
            if sample.time > now { continue }
            if let windowStart, sample.time < windowStart { break }
            // Readings wobble slightly; a drop larger than `resetDrop` when walking forward means a reset.
            guard let v = sample.values[window], v - low <= resetDrop else { break }
            low = min(low, v)
            earlier = (sample.time, v)
            if now.timeIntervalSince(sample.time) >= lookback { break }
        }
        guard let (time, v) = earlier, now.timeIntervalSince(time) >= 600 else { return nil }
        return max(0, value - v) / now.timeIntervalSince(time)
    }
}

/// Figures for the dashboard's stat tiles.
public struct PoolSummary: Sendable, Hashable {
    /// Mean share left on each Claude account's weekly window, 0 to 100.
    public var claudeLeft: Double?
    public var exhausted: Bool
    public var freeAgainAt: Date?
    /// Earliest projected hard wall across direct windows or the last open pooled account.
    public var nextLimit: (account: String, window: String, at: Date)?
    /// Earliest projected routine switch in the TeamClaude pool while another Claude account has headroom.
    public var nextRotation: (account: String, window: String, at: Date)?

    public init(claudeLeft: Double? = nil, exhausted: Bool = false, freeAgainAt: Date? = nil,
                nextLimit: (account: String, window: String, at: Date)? = nil,
                nextRotation: (account: String, window: String, at: Date)? = nil) {
        self.claudeLeft = claudeLeft
        self.exhausted = exhausted
        self.freeAgainAt = freeAgainAt
        self.nextLimit = nextLimit
        self.nextRotation = nextRotation
    }

    public static func == (a: PoolSummary, b: PoolSummary) -> Bool {
        a.claudeLeft == b.claudeLeft && a.exhausted == b.exhausted && a.freeAgainAt == b.freeAgainAt
            && a.nextLimit?.account == b.nextLimit?.account
            && a.nextLimit?.window == b.nextLimit?.window
            && a.nextLimit?.at == b.nextLimit?.at
            && a.nextRotation?.account == b.nextRotation?.account
            && a.nextRotation?.window == b.nextRotation?.window
            && a.nextRotation?.at == b.nextRotation?.at
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(claudeLeft)
        hasher.combine(exhausted)
        hasher.combine(freeAgainAt)
        hasher.combine(nextLimit?.account)
        hasher.combine(nextLimit?.window)
        hasher.combine(nextLimit?.at)
        hasher.combine(nextRotation?.account)
        hasher.combine(nextRotation?.window)
        hasher.combine(nextRotation?.at)
    }

    public static func make(accounts: [AccountSnapshot], history: History, now: Date,
                            threshold: Double = Levels.full) -> PoolSummary {
        let lanes = CapacityLane.build(accounts: accounts, proxyThreshold: threshold) { $0.title ?? $0.id }
        let claudeLane = lanes.first { $0.provider == .claude }
        let claude = accounts.filter { $0.provider == .claude }
        let left = claudeLane?.weeklyLeft(at: now)
        let exhausted = !claude.isEmpty && claude.allSatisfy { $0.tier(at: now, full: threshold) == .full }
        let freeAgain = exhausted ? claude.compactMap { $0.freeAgainAt(full: threshold) }.min() : nil

        var nextWall: (String, String, Date)?
        var nextRot: (String, String, Date)?
        for account in accounts where !account.isStale(at: now) {
            let limit = account.effectiveThreshold(proxyThreshold: threshold)
            let isRoutineSwitch = account.provider == .claude
                && (claudeLane?.hasHeadroom(excluding: account.id, at: now) ?? false)
            for window in account.windows {
                guard let pace = PaceModel.pace(for: window, samples: history.samples(account.id), now: now,
                                                observedAt: account.fetchedAt, threshold: limit),
                      let at = pace.fullAt else { continue }
                if isRoutineSwitch {
                    if nextRot == nil || at < nextRot!.2 { nextRot = (account.id, window.id, at) }
                } else {
                    if nextWall == nil || at < nextWall!.2 { nextWall = (account.id, window.id, at) }
                }
            }
        }
        return PoolSummary(
            claudeLeft: left,
            exhausted: exhausted,
            freeAgainAt: freeAgain,
            nextLimit: nextWall.map { (account: $0.0, window: $0.1, at: $0.2) },
            nextRotation: nextRot.map { (account: $0.0, window: $0.1, at: $0.2) }
        )
    }
}
