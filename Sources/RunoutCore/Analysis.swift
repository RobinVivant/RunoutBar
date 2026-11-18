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
    /// Pace for one window. Prefers the proxy's own forecast, then the measured
    /// rate over the last half hour, then the average since the window began.
    public static func pace(for window: LimitWindow, samples: [Sample], now: Date,
                            threshold: Double = Levels.full) -> Pace? {
        guard let used = window.used, let reset = window.resetsAt, let duration = window.duration,
              reset > now, let elapsed = window.elapsed(at: now) else { return nil }
        let remaining = reset.timeIntervalSince(now)

        var rate: Double?  // percent per second
        var basis: Pace.Basis?
        var fullAt: Date?
        if let forecast = window.forecast, let perHour = forecast.ratePerHour, perHour > 1e-6 {
            rate = perHour / 3600
            basis = .proxyForecast
            if let at = forecast.reachesThresholdAt, at > now, at < reset { fullAt = at }
        } else if let measured = recentRate(samples: samples, window: window.id, value: used, now: now,
                                            windowStart: window.windowStart) {
            rate = measured
            basis = .recent
        } else if elapsed > 0.05 {
            rate = used / (elapsed * duration)
            basis = .windowAverage
        }

        if fullAt == nil, let rate, rate > 0, used < threshold {
            let at = now.addingTimeInterval((threshold - used) / rate)
            if at < reset { fullAt = at }
        }
        let atReset = min(100, used + (rate ?? 0) * remaining)
        return Pace(even: elapsed * 100, ratePerHour: rate.map { $0 * 3600 }, basis: basis, fullAt: fullAt,
                    atReset: atReset)
    }

    /// Percent per second over roughly the last half hour, within the current window.
    static func recentRate(samples: [Sample], window: String, value: Double, now: Date,
                           windowStart: Date? = nil, lookback: TimeInterval = 1800) -> Double? {
        var earlier: (Date, Double)?
        var newer = value
        for sample in samples.reversed() {
            if let windowStart, sample.time < windowStart { break }
            // Usage only grows within a window, so an older value above a newer one means a reset between them.
            guard let v = sample.values[window], v <= newer else { break }
            earlier = (sample.time, v)
            newer = v
            if now.timeIntervalSince(sample.time) >= lookback { break }
        }
        guard let (time, v) = earlier, now.timeIntervalSince(time) >= 600 else { return nil }
        return (value - v) / now.timeIntervalSince(time)
    }
}

/// Figures for the dashboard's stat tiles.
public struct PoolSummary: Sendable, Hashable {
    /// Mean share left on each Claude account's fullest window, 0 to 100.
    public var claudeLeft: Double?
    public var exhausted: Bool
    public var freeAgainAt: Date?
    /// Earliest projected limit across all windows, if any lands before its reset.
    public var nextLimit: (account: String, window: String, at: Date)?

    public static func == (a: PoolSummary, b: PoolSummary) -> Bool {
        a.claudeLeft == b.claudeLeft && a.exhausted == b.exhausted && a.freeAgainAt == b.freeAgainAt
            && a.nextLimit?.at == b.nextLimit?.at
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(claudeLeft)
        hasher.combine(exhausted)
    }

    public static func make(accounts: [AccountSnapshot], history: History, now: Date,
                            threshold: Double = Levels.full) -> PoolSummary {
        let claude = accounts.filter { $0.provider == .claude }
        let known = claude.filter { $0.isKnown(at: now) || $0.isPartial(at: now) }
        let left = known.isEmpty || known.count < claude.count
            ? nil : known.map { 100 - ($0.peak ?? 0) }.reduce(0, +) / Double(known.count)
        let exhausted = !claude.isEmpty && claude.allSatisfy { $0.tier(at: now, full: threshold) == .full }
        let freeAgain = exhausted ? claude.compactMap { $0.freeAgainAt(full: threshold) }.min() : nil

        var next: (String, String, Date)?
        for account in accounts where !account.isStale(at: now) {
            for window in account.windows {
                guard let pace = PaceModel.pace(for: window, samples: history.samples(account.id), now: now,
                                                threshold: threshold),
                      let at = pace.fullAt else { continue }
                if next == nil || at < next!.2 { next = (account.id, window.id, at) }
            }
        }
        return PoolSummary(claudeLeft: left, exhausted: exhausted, freeAgainAt: freeAgain,
                           nextLimit: next.map { (account: $0.0, window: $0.1, at: $0.2) })
    }
}
