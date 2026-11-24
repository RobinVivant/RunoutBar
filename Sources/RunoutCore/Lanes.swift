import Foundation

/// One fungible quota tank that work draws from: either a pooled proxy lane (such as Anthropic
/// accounts rotated by TeamClaude) or a direct CLI quota bucket (Codex or a Google AI group).
public struct CapacityLane: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case pooled(proxy: String, switchThreshold: Double)
        case direct(source: String)

        public var isPooled: Bool {
            if case .pooled = self { return true }
            return false
        }
    }

    public var id: String
    public var provider: Provider
    public var title: String
    public var kind: Kind
    public var accounts: [AccountSnapshot]
    public var threshold: Double

    public init(id: String, provider: Provider, title: String, kind: Kind,
                accounts: [AccountSnapshot], threshold: Double) {
        self.id = id
        self.provider = provider
        self.title = title
        self.kind = kind
        self.accounts = accounts
        self.threshold = threshold
    }

    /// Groups accounts into capacity lanes in display order: all `.claude` accounts form one
    /// TeamClaude pool lane at the position of the first Claude account, while each direct
    /// Codex or Google AI account forms its own independent lane.
    public static func build(accounts: [AccountSnapshot], proxyThreshold: Double = Levels.full,
                             label: (AccountSnapshot) -> String) -> [CapacityLane] {
        var lanes: [CapacityLane] = []
        let claudeAccounts = accounts.filter { $0.provider == .claude }
        var insertedClaude = false
        for account in accounts {
            switch account.provider {
            case .claude:
                guard !insertedClaude else { continue }
                insertedClaude = true
                lanes.append(CapacityLane(
                    id: "claude",
                    provider: .claude,
                    title: "Claude",
                    kind: .pooled(proxy: "TeamClaude", switchThreshold: proxyThreshold),
                    accounts: claudeAccounts,
                    threshold: proxyThreshold
                ))
            case .codex:
                lanes.append(CapacityLane(
                    id: account.id,
                    provider: .codex,
                    title: label(account),
                    kind: .direct(source: "Codex CLI"),
                    accounts: [account],
                    threshold: 100
                ))
            case .google:
                lanes.append(CapacityLane(
                    id: account.id,
                    provider: .google,
                    title: label(account),
                    kind: .direct(source: "Antigravity CLI"),
                    accounts: [account],
                    threshold: 100
                ))
            }
        }
        return lanes
    }

    /// Mean percentage of weekly capacity remaining across every account in this lane.
    /// Returns nil when any account is stale or lacks a weekly reading; returns 0 when all are at or past `threshold`.
    public func weeklyLeft(at now: Date) -> Double? {
        guard !accounts.isEmpty else { return nil }
        var values: [Double] = []
        for account in accounts {
            guard !account.isStale(at: now), let weekly = account.weekly, let used = weekly.used else { return nil }
            values.append(used)
        }
        if values.allSatisfy({ $0 >= threshold }) { return 0 }
        return values.map { max(0, 100 - $0) }.reduce(0, +) / Double(values.count)
    }

    public func weeklyUsed(at now: Date) -> Double? {
        weeklyLeft(at: now).map { 100 - $0 }
    }

    /// Fresh accounts in this lane not yet at `threshold`.
    public func openAccountsCount(at now: Date) -> Int {
        accounts.count { !$0.isStale(at: now) && $0.tier(at: now, full: threshold) != .full }
    }

    /// True when this is a pooled lane and another fresh account besides `accountID` still has headroom.
    public func hasHeadroom(excluding accountID: String, at now: Date) -> Bool {
        guard kind.isPooled else { return false }
        return accounts.contains {
            $0.id != accountID && !$0.isStale(at: now) && $0.tier(at: now, full: threshold) != .full
        }
    }

    public var bankedResets: Int {
        accounts.reduce(0) { $0 + ($1.resets?.available ?? 0) }
    }
}

/// Work-week run-out status for one capacity lane.
public struct LaneRunOut: Identifiable, Sendable, Hashable {
    public var id: String { lane.id }
    public var lane: CapacityLane
    public var runOut: PoolRunOut?
    public var weeklyLeft: Double?
    public var openAccounts: Int
    public var bankedResets: Int

    public init(lane: CapacityLane, runOut: PoolRunOut?, weeklyLeft: Double?,
                openAccounts: Int, bankedResets: Int) {
        self.lane = lane
        self.runOut = runOut
        self.weeklyLeft = weeklyLeft
        self.openAccounts = openAccounts
        self.bankedResets = bankedResets
    }
}

/// Cross-provider work-week summary: per-lane projections plus the bottleneck lane.
public struct GlobalRunOut: Sendable, Hashable {
    public var lanes: [LaneRunOut]
    public var target: Date?
    public var bottleneck: LaneRunOut?
    public var shortCount: Int
    public var state: PoolRunOut.State

    public init(lanes: [LaneRunOut], target: Date?, bottleneck: LaneRunOut?,
                shortCount: Int, state: PoolRunOut.State) {
        self.lanes = lanes
        self.target = target
        self.bottleneck = bottleneck
        self.shortCount = shortCount
        self.state = state
    }

    public static func make(lanes: [CapacityLane], history: History, now: Date, week: WorkWeek,
                            calendar: Calendar = .current) -> GlobalRunOut {
        let target = week.weekEnd(after: now, calendar: calendar)
        let entries = lanes.map { lane in
            LaneRunOut(
                lane: lane,
                runOut: PoolRunOut.make(lane: lane, history: history, now: now, week: week, calendar: calendar),
                weeklyLeft: lane.weeklyLeft(at: now),
                openAccounts: lane.openAccountsCount(at: now),
                bankedResets: lane.bankedResets
            )
        }
        let shortOrCritical = entries.filter { entry in
            guard let state = entry.runOut?.state else { return false }
            return state == .short || state == .critical
        }
        let bottleneck = shortOrCritical.min { a, b in
            let sa = a.runOut?.state == .critical ? 0 : 1
            let sb = b.runOut?.state == .critical ? 0 : 1
            if sa != sb { return sa < sb }
            return (a.runOut?.at ?? .distantFuture) < (b.runOut?.at ?? .distantFuture)
        }
        let state: PoolRunOut.State
        if shortOrCritical.contains(where: { $0.runOut?.state == .critical }) {
            state = .critical
        } else if !shortOrCritical.isEmpty {
            state = .short
        } else if entries.contains(where: { $0.runOut?.state == .lasts }) {
            state = .lasts
        } else {
            state = .idle
        }
        return GlobalRunOut(lanes: entries, target: target, bottleneck: bottleneck,
                            shortCount: shortOrCritical.count, state: state)
    }
}
