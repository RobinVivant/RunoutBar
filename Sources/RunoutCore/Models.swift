import Foundation

public enum Provider: String, Codable, Sendable {
    case claude
    case codex
    case google
}

/// The proxy's own projection for one window, converted to percent.
public struct Forecast: Sendable, Hashable {
    /// Percent of the window per hour.
    public var ratePerHour: Double?
    public var reachesThresholdAt: Date?
    public var threshold: Double

    public init(ratePerHour: Double?, reachesThresholdAt: Date?, threshold: Double) {
        self.ratePerHour = ratePerHour
        self.reachesThresholdAt = reachesThresholdAt
        self.threshold = threshold
    }
}

/// One rate-limit window: a 5-hour session, the weekly limit, or a per-model weekly limit.
public struct LimitWindow: Identifiable, Sendable, Hashable {
    /// Stable key, also used in history: "5h", "7d", "7d.fable".
    public var id: String
    public var title: String
    /// Percent used, 0 to 100, or nil when the window is known but has no reading.
    public var used: Double?
    public var resetsAt: Date?
    public var duration: TimeInterval?
    public var forecast: Forecast?

    public init(id: String, title: String, used: Double?, resetsAt: Date?, duration: TimeInterval?,
                forecast: Forecast? = nil) {
        self.id = id
        self.title = title
        self.used = used
        self.resetsAt = resetsAt
        self.duration = duration
        self.forecast = forecast
    }

    public var isWeekly: Bool { duration == 7 * 86_400 }

    public var windowStart: Date? {
        guard let resetsAt, let duration else { return nil }
        return resetsAt.addingTimeInterval(-duration)
    }

    /// Share of the window already elapsed, 0 to 1.
    public func elapsed(at now: Date) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / duration))
    }
}

/// Why an account shows no 5-hour window.
public enum SessionWindowNote: Sendable, Hashable {
    /// The account is configured or reported as having no 5-hour limit.
    case noLimit
    /// The latest readings no longer carry a 5-hour window; the last one is this old.
    case notReportedSince(Date)
}

/// One banked reset, when the source lists them individually.
public struct ResetGrant: Identifiable, Sendable, Hashable {
    /// Opaque id the source redeems by. Never shown.
    public var id: String
    public var title: String?
    public var grantedAt: Date?
    public var expiresAt: Date?
    /// False while the source reports it as being redeemed or already used.
    public var available = true

    public init(id: String, title: String? = nil, grantedAt: Date? = nil, expiresAt: Date? = nil,
                available: Bool = true) {
        self.id = id
        self.title = title
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.available = available
    }
}

/// Banked resets: grants that clear an account's limits before their own reset.
public struct ResetCredits: Sendable, Hashable {
    /// Banked and not expired.
    public var available: Int
    /// How many the source says can be spent right now; nil when it does not say.
    public var usableNow: Int?
    /// Of `available`, how many clear only the Fable weekly limit.
    public var fableOnly = 0
    /// The earliest expiry among them.
    public var nextExpiry: Date?
    public var seenAt: Date?
    /// Individual resets, when the source lists them; nil when only counts are known.
    public var grants: [ResetGrant]?

    public init(available: Int, usableNow: Int? = nil, fableOnly: Int = 0, nextExpiry: Date? = nil,
                seenAt: Date? = nil, grants: [ResetGrant]? = nil) {
        self.available = available
        self.usableNow = usableNow
        self.fableOnly = fableOnly
        self.nextExpiry = nextExpiry
        self.seenAt = seenAt
        self.grants = grants
    }

    /// The reset a manual redeem names: the listed one that expires first. Nil lets the source pick.
    public var nextGrant: ResetGrant? { grants?.first }
}

public struct TokenTotals: Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheCreation: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheCreation: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
    }

    public var total: Double { input + output + cacheRead + cacheCreation }
}

public struct AccountSnapshot: Identifiable, Sendable, Hashable {
    /// TeamClaude account name, "openai" for the Codex login, or "google.<group>" for a Google AI quota group.
    public var id: String
    public var provider: Provider
    /// The name the source gives the account, when its id is not one to show.
    public var title: String?
    /// What the limits cover, in the source's words: the models of a Google AI quota group.
    public var covers: String?
    public var windows: [LimitWindow] = []
    public var fetchedAt: Date?
    /// Age after which a reading counts as stale; longer when usage checks are spaced out.
    public var staleAfter: TimeInterval = Levels.staleAfter
    public var error: String?
    public var warning: String?
    public var blocked = false
    public var sessionNote: SessionWindowNote?
    public var routing = false
    public var sessions = 0
    public var knownSessions = 0
    public var unavailable: String?
    public var status: String?
    public var extraUsage: Bool?
    public var spend: String?
    /// Banked resets; nil when the source reports none or the account is not eligible.
    public var resets: ResetCredits?
    public var recentRequests = 0
    public var totalRequests = 0
    public var lastUsed: Date?
    public var tokens: TokenTotals?
    /// Model ids, most recent first.
    public var recentModels: [String] = []
    public var plan: String?
    /// The sign-in the account's readings depend on, when its source reports one.
    public var signIn: SignIn?

    public init(id: String, provider: Provider) {
        self.id = id
        self.provider = provider
    }

    public static func unavailable(_ id: String, provider: Provider, error: String) -> AccountSnapshot {
        var snapshot = AccountSnapshot(id: id, provider: provider)
        snapshot.error = error
        return snapshot
    }

    public func window(_ id: String) -> LimitWindow? { windows.first { $0.id == id } }

    /// The weekly window the pace chart and menu bar use.
    public var weekly: LimitWindow? { window("7d") ?? windows.first(where: \.isWeekly) }
}

public struct ProxySnapshot: Sendable, Hashable {
    public var up = false
    public var version: String?
    public var updateFlag = false
    public var uptime: TimeInterval?
    public var pid: Int?
    public var probeInterval: Int = 0
    public var activeSessions = 0
    public var knownSessions = 0
    public var currentAccount: String?
    /// Utilization at which TeamClaude rotates away from an account, in percent.
    public var threshold: Double = 98
    public var eventLoopLagMs: Double?
    public var eventLoopMaxLagMs: Double?
    public var stallCount = 0
    public var callbackLastSync: Date?
    public var callbackError: String?
    public var signInNeeded = 0
    /// Sign-ins of the Codex accounts TeamClaude routes to. They are apart from the Codex CLI's own login.
    public var codexSignIns: [SignIn] = []
    /// The accounts the proxy routes to, of every provider.
    public var accountCount = 0
    public var upstreamActive = 0
    public var upstreamQueued = 0
    public var tokens: TokenTotals?
    public var activeContext: Double?
    public var error: String?

    public init() {}

    public static func down(_ error: String?) -> ProxySnapshot {
        var proxy = ProxySnapshot()
        proxy.error = error
        return proxy
    }
}
