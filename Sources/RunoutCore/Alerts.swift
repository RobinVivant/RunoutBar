import Foundation

public struct Notice: Sendable, Hashable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// What the last evaluation saw, so only changes notify.
public struct AlertState: Codable, Sendable, Hashable {
    public var tiers: [String: Tier] = [:]
    public var exhausted = false
    public var proxyUp: Bool?
    /// Consecutive failed status reads; one alone is not an outage.
    public var proxyFailures: Int?
    public var announcedUpdate: String?
    /// Set once a release check has succeeded, so the first one only records.
    public var updateChecked: Bool?

    public init() {}
}

public enum Alerts {
    /// Compare with the previous state. With no previous state, record only.
    /// `proxyRestarting` is true while the app itself restarts the proxy, which is not an outage.
    public static func evaluate(accounts: [AccountSnapshot], proxyUp: Bool, proxyRestarting: Bool = false,
                                latestTeamClaude: String?, installedTeamClaude: String?, previous: AlertState?,
                                now: Date, label: (String) -> String, threshold: Double = Levels.full)
        -> (state: AlertState, notices: [Notice]) {
        var state = previous ?? AlertState()
        var notices: [Notice] = []
        let first = previous == nil

        for account in accounts {
            guard let tier = account.tier(at: now, full: threshold) else { continue }
            let old = state.tiers[account.id]
            state.tiers[account.id] = tier
            guard !first, let old, old != tier, let top = account.peakWindow else { continue }
            let name = label(account.id)
            switch (old, tier) {
            case (_, .full):
                let reset = top.resetsAt.map { " Resets \(Format.dayTime($0))." } ?? ""
                notices.append(Notice(title: name, body: "\(top.title) limit reached.\(reset)"))
            case (.ok, .high):
                notices.append(Notice(title: name, body: "\(top.title) limit at \(Int((top.used ?? 0).rounded()))%."))
            case (.full, .ok):
                notices.append(Notice(title: name, body: "Limit reset. Available again."))
            case (.full, .high):
                notices.append(Notice(title: name,
                                      body: "Back in rotation. \(top.title) at \(Int((top.used ?? 0).rounded()))%."))
            default:
                break
            }
        }

        // Only a complete set of readings can change the verdict; a stale account is not news.
        let claudeTiers = accounts.filter { $0.provider == .claude }.map { $0.tier(at: now, full: threshold) }
        if !claudeTiers.isEmpty, claudeTiers.allSatisfy({ $0 != nil }) {
            let exhausted = claudeTiers.allSatisfy { $0 == .full }
            if !first, exhausted, !state.exhausted {
                notices.append(Notice(title: "No Claude capacity left", body: "Every Claude account is past its limit."))
            }
            state.exhausted = exhausted
        }

        if !proxyRestarting {
            if proxyUp {
                if !first, state.proxyUp == false {
                    notices.append(Notice(title: "TeamClaude proxy", body: "Responding again."))
                }
                state.proxyUp = true
                state.proxyFailures = nil
            } else {
                let failures = (state.proxyFailures ?? 0) + 1
                state.proxyFailures = failures
                if failures >= 2 || state.proxyUp == nil {
                    if !first, state.proxyUp == true {
                        notices.append(Notice(title: "TeamClaude proxy", body: "Not responding."))
                    }
                    state.proxyUp = false
                }
            }
        }

        if let latest = latestTeamClaude {
            let baseline = state.updateChecked != true
            state.updateChecked = true
            if let installed = installedTeamClaude, SemVer.isNewer(latest, than: installed),
               state.announcedUpdate != latest {
                if !first, !baseline {
                    notices.append(Notice(title: "TeamClaude \(latest) available",
                                          body: "You have \(installed). Update from the Proxy tab."))
                }
                state.announcedUpdate = latest
            }
        }
        return (state, notices)
    }
}
