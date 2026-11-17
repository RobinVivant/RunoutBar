import Foundation
import UsageCore

/// Made-up accounts and usage for `--demo`: the app and its snapshots run without TeamClaude,
/// Codex or any account. Every time is relative to now, so the data always looks current.
enum DemoData {
    static let personal = "ada@example.com"
    static let work = "work@example.com"
    static let team = "team@example.com"

    static var config: AppConfig {
        var config = AppConfig()
        config.accounts = [
            personal: AccountStyle(letter: "P", label: "Personal", color: "#0a84ff", noFiveHourLimit: true),
            work: AccountStyle(letter: "W", label: "Work", color: "#bf5af2"),
            team: AccountStyle(letter: "T", label: "Team", color: "#30d1b2"),
            AppConfig.codexKey: AccountStyle(letter: "O", label: "Codex", color: "#ff6482"),
        ]
        config.order = [personal, work, team, AppConfig.codexKey]
        return config
    }

    /// Weekly use now, hours until the weekly reset, and the use the week before ended on.
    private static let weeks: [(id: String, used: Double, resetIn: Double, previous: Double)] = [
        (personal, 71, 52, 88), (work, 34, 99, 61), (team, 86, 29, 97), (AppConfig.codexKey, 18, 121, 40),
    ]
    private static let week: TimeInterval = 7 * 86_400

    static func accounts(now: Date) -> [AccountSnapshot] {
        weeks.map { entry in
            let reset = now.addingTimeInterval(entry.resetIn * 3600)
            var account = AccountSnapshot(id: entry.id, provider: entry.id == AppConfig.codexKey ? .codex : .claude)
            account.fetchedAt = now
            account.windows = [LimitWindow(id: "7d", title: "Weekly", used: entry.used, resetsAt: reset, duration: week)]
            switch entry.id {
            case personal:
                account.windows[0].forecast = Forecast(ratePerHour: 2.4, reachesThresholdAt: now.addingTimeInterval(11.25 * 3600),
                                                       threshold: 98)
                account.windows.append(LimitWindow(id: "7d.fable", title: "Fable weekly", used: 44, resetsAt: reset,
                                                   duration: week))
                account.sessionNote = .noLimit
                account.routing = true
                account.sessions = 4
                account.knownSessions = 23
                account.recentRequests = 212
                account.totalRequests = 1840
                account.lastUsed = now.addingTimeInterval(-8)
                account.tokens = TokenTotals(input: 410_000, output: 1_300_000, cacheRead: 196_000_000, cacheCreation: 9_400_000)
                account.recentModels = ["claude-opus-5-5", "claude-fable-5-2", "claude-haiku-5-5"]
                account.extraUsage = false
                account.spend = "$0.00 spent"
                account.resets = ResetCredits(available: 3, usableNow: 3, fableOnly: 2,
                                              nextExpiry: now.addingTimeInterval(23 * 86_400), seenAt: now)
            case work:
                account.windows.insert(LimitWindow(id: "5h", title: "5-hour", used: 41,
                                                   resetsAt: now.addingTimeInterval(2.6 * 3600), duration: 5 * 3600), at: 0)
                account.sessions = 1
                account.knownSessions = 9
                account.recentRequests = 38
                account.totalRequests = 620
                account.lastUsed = now.addingTimeInterval(-340)
                account.tokens = TokenTotals(input: 96_000, output: 280_000, cacheRead: 41_000_000, cacheCreation: 2_100_000)
                account.recentModels = ["claude-sonnet-5-5"]
                account.resets = ResetCredits(available: 1, usableNow: 1, nextExpiry: now.addingTimeInterval(40 * 86_400),
                                              seenAt: now)
            case team:
                account.windows.insert(LimitWindow(id: "5h", title: "5-hour", used: 12,
                                                   resetsAt: now.addingTimeInterval(4.1 * 3600), duration: 5 * 3600), at: 0)
                account.knownSessions = 14
                account.totalRequests = 2310
                account.lastUsed = now.addingTimeInterval(-3 * 3600)
                account.tokens = TokenTotals(input: 220_000, output: 610_000, cacheRead: 88_000_000, cacheCreation: 4_000_000)
                account.recentModels = ["claude-opus-5-5"]
            default:
                account.plan = "Pro"
                account.resets = ResetCredits(
                    available: 2, nextExpiry: now.addingTimeInterval(12 * 86_400), seenAt: now,
                    grants: [ResetGrant(id: "demo-1", title: "Weekly reset", expiresAt: now.addingTimeInterval(12 * 86_400)),
                             ResetGrant(id: "demo-2", title: "Weekly reset", expiresAt: now.addingTimeInterval(33 * 86_400))])
            }
            return account
        }
    }

    static func proxy(now: Date) -> ProxySnapshot {
        var proxy = ProxySnapshot()
        proxy.up = true
        proxy.version = "1.1.30"
        proxy.uptime = 3.4 * 86_400
        proxy.pid = 4242
        proxy.probeInterval = 60
        proxy.activeSessions = 5
        proxy.knownSessions = 46
        proxy.currentAccount = personal
        proxy.eventLoopLagMs = 1.1
        proxy.eventLoopMaxLagMs = 18
        proxy.callbackLastSync = now.addingTimeInterval(-40)
        proxy.upstreamActive = 2
        proxy.tokens = TokenTotals(input: 726_000, output: 2_190_000, cacheRead: 325_000_000, cacheCreation: 15_500_000)
        proxy.activeContext = 412_000
        return proxy
    }

    /// Eight days of samples: use climbs during work hours, barely moves at night and at the
    /// weekend, and drops to zero at each weekly reset.
    static func history(now: Date) -> History {
        var history = History()
        let calendar = Calendar.current
        for entry in weeks {
            let start = now.addingTimeInterval(entry.resetIn * 3600 - week)
            func activity(_ time: Date) -> Double {
                let parts = calendar.dateComponents([.weekday, .hour], from: time)
                let workday = (2...6).contains(parts.weekday ?? 1), hour = parts.hour ?? 0
                return workday && (9..<19).contains(hour) ? 1 : 0.06
            }
            // Burn so far in the current week, and over the whole of the week before.
            let step: TimeInterval = 900
            let times = stride(from: now.addingTimeInterval(-History.retention + step), through: now, by: step).map { $0 }
            let current = times.filter { $0 >= start }.reduce(0) { $0 + activity($1) }
            let before = stride(from: start.addingTimeInterval(-week), to: start, by: step).reduce(0) { $0 + activity($1) }
            var samples: [Sample] = []
            var burned = 0.0, earlier = stride(from: start.addingTimeInterval(-week), to: times[0], by: step)
                .reduce(0) { $0 + activity($1) }
            for time in times {
                var values: [String: Double]
                if time < start {
                    earlier += activity(time)
                    values = ["7d": (entry.previous * earlier / max(before, 1)).rounded()]
                } else {
                    burned += activity(time)
                    values = ["7d": (entry.used * burned / max(current, 1)).rounded()]
                    if entry.id == personal { values["7d.fable"] = (44 * pow(burned / max(current, 1), 1.6)).rounded() }
                }
                if samples.last?.values != values || time.timeIntervalSince(samples.last?.time ?? .distantPast) >= History.heartbeat {
                    samples.append(Sample(time: time, values: values))
                }
            }
            history.accounts[entry.id] = samples
        }
        return history
    }

    /// What Anthropic would list for the personal account.
    static func resets(now: Date) -> ClaudeResetStatus? {
        func millis(_ days: Double) -> Double { now.addingTimeInterval(days * 86_400).timeIntervalSince1970 * 1000 }
        let json = """
        {"ok": true, "eligible": true, "atLimit": false, "exhausted": [], "nextGrantId": "demo-weekly", "grants": [
          {"id": "demo-weekly", "kind": "weekly", "resetsLeft": 1, "resetsTotal": 1,
           "clears": ["seven_day", "seven_day_overage_included"], "endsAt": \(millis(23)), "usableNow": true, "paused": false},
          {"id": "demo-fable", "kind": "fable", "resetsLeft": 2, "resetsTotal": 2,
           "clears": ["seven_day_overage_included"], "endsAt": \(millis(112)), "usableNow": true, "paused": false}]}
        """
        return try? ClaudeResets.parseStatus(JSONValue.parse(Data(json.utf8)), now: now)
    }
}
