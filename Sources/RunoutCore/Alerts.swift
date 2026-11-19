import Foundation

public struct Notice: Sendable, Hashable {
    public var title: String
    public var body: String
    /// The id of the sign-in the notice is about, which a click on it opens.
    public var signIn: String?

    public init(title: String, body: String, signIn: String? = nil) {
        self.title = title
        self.body = body
        self.signIn = signIn
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
    /// The stage each sign-in was last announced at, by sign-in id.
    public var signIns: [String: SignIn.Stage]?

    public init() {}
}

public enum Alerts {
    /// Compare with the previous state. With no previous state, record only.
    /// `proxyRestarting` is true while the app itself restarts the proxy, which is not an outage.
    public static func evaluate(accounts: [AccountSnapshot], signIns: [SignIn] = [], proxyUp: Bool,
                                proxyRestarting: Bool = false,
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

        // A sign-in is announced once per stage as it nears its end. A state saved before sign-ins were
        // tracked has no record, so what is already due is announced then.
        // A read that could not list the sign-ins says nothing about them: their record stays, so an outage
        // or a launch ahead of the proxy does not announce them again. Only a proxy that answers lists
        // its sign-ins in full, and one it no longer lists is forgotten.
        var stages = state.signIns ?? [:]
        if proxyUp {
            let codex = "\(SignIn.Holder.codex.rawValue):"
            stages = stages.filter { $0.key.hasPrefix(codex) }
        }
        for signIn in signIns {
            let stage = signIn.stage(at: now)
            let old = state.signIns?[signIn.id] ?? .ok
            stages[signIn.id] = stage
            guard !first, stage > old else { continue }
            notices.append(Notice(title: signInTitle(signIn, label: label), body: signInBody(signIn, now: now),
                                  signIn: signIn.id))
        }
        state.signIns = stages

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

    /// A Codex account in the proxy goes by its role: its name there says nothing next to the Codex row.
    public static func signInTitle(_ signIn: SignIn, label: (String) -> String) -> String {
        signIn.holder == .teamclaudeCodex ? "Codex in TeamClaude" : label(signIn.account)
    }

    static func signInBody(_ signIn: SignIn, now: Date) -> String {
        let headline = signIn.headline(now: now)
        if let failure = signIn.failure {
            let detail = failure.detail.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            let next = !(failure.fixedBySigningIn || failure.code == "error") ? "Resolve it with the provider first."
                : signIn.manual ? "Renew it with the command Runout Bar shows." : "Reconnect it from Runout Bar."
            return "\(headline): \(detail). \(next)"
        }
        // A long-lived token is renewed in a terminal; the app shows the command.
        let renew = signIn.manual ? "Renew it with the command Runout Bar shows" : "Reconnect it from Runout Bar"
        guard let expiresAt = signIn.expiresAt, expiresAt > now else { return "\(headline). \(renew)." }
        return "\(headline), \(SignIn.when(expiresAt, now: now)). \(renew) to keep it in rotation."
    }
}
