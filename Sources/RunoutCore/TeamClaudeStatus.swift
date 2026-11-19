import Foundation

/// Maps `teamclaude status --json` into account and proxy snapshots. This reads
/// quota the running proxy already probed; it never calls Anthropic itself.
public enum TeamClaudeStatus {
    static let fiveHours: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86_400

    public static func parse(_ data: Data, config: AppConfig) throws -> (accounts: [AccountSnapshot], proxy: ProxySnapshot) {
        let status = try JSONValue.parse(data)
        guard status.object != nil else { throw ParseError.notAnObject }

        let threshold = (status["switchThreshold"]?.double ?? 0.98) * 100
        let current = status["currentAccounts"]?["anthropic"]?.string ?? status["currentAccount"]?.string
        let probes = status["probe"]?["accounts"]?.array ?? []
        let accounts = status["accounts"]?.array ?? []

        var snapshots: [AccountSnapshot] = []
        var codexSignIns: [SignIn] = []
        for (index, account) in accounts.enumerated() {
            guard account["disabled"]?.bool != true, let name = account["name"]?.string else { continue }
            if account["provider"]?.string == "codex" {
                if let signIn = signIn(name: name, account: account, holder: .teamclaudeCodex) { codexSignIns.append(signIn) }
                continue
            }
            guard account["provider"]?.string == "anthropic" else { continue }
            // Both arrays follow the router's account order. Names can repeat across
            // providers, so a name-keyed lookup could pick Codex's probe instead.
            var probe = index < probes.count ? probes[index] : nil
            if probe?["name"]?.string != name {
                let matches = probes.filter { $0["name"]?.string == name }
                probe = matches.count == 1 ? matches[0] : nil
            }
            snapshots.append(claudeAccount(name: name, account: account, probe: probe, current: current,
                                           threshold: threshold, config: config))
        }

        var proxy = ProxySnapshot()
        let server = status["server"]
        proxy.up = true
        proxy.version = server?["versionLabel"]?.string ?? server?["version"]?.string
        proxy.updateFlag = server?["updateAvailable"]?.bool ?? false
        proxy.uptime = server?["uptimeSeconds"]?.double
        proxy.pid = server?["pid"]?.int
        proxy.eventLoopLagMs = server?["eventLoop"]?["lastLagMs"]?.double
        proxy.eventLoopMaxLagMs = server?["eventLoop"]?["maxLagMs"]?.double
        proxy.stallCount = server?["eventLoop"]?["stallCount"]?.int ?? 0
        let probe = status["probe"]
        proxy.probeInterval = probe?["enabled"]?.bool == true ? (probe?["intervalSeconds"]?.int ?? 0) : 0
        let staleAfter = Levels.staleAfter(probeInterval: proxy.probeInterval)
        for index in snapshots.indices { snapshots[index].staleAfter = staleAfter }
        proxy.activeSessions = status["sessions"]?["active"]?.int ?? 0
        proxy.knownSessions = status["sessions"]?["known"]?.int ?? 0
        proxy.currentAccount = current
        proxy.threshold = threshold
        proxy.callbackLastSync = date(fromMillis: status["callbackSync"]?["lastSyncAt"])
        proxy.callbackError = status["callbackSync"]?["lastError"]?.text
        proxy.signInNeeded = status["callbackSync"]?["signInNeeded"]?.int ?? 0
        proxy.codexSignIns = codexSignIns
        proxy.upstreamActive = status["upstreamPool"]?["active"]?.int ?? 0
        proxy.upstreamQueued = status["upstreamPool"]?["queued"]?.int ?? 0
        if let tokens = status["sessions"]?["tokens"] {
            proxy.tokens = TokenTotals(input: tokens["input"]?.double ?? 0, output: tokens["output"]?.double ?? 0,
                                       cacheRead: tokens["cacheRead"]?.double ?? 0,
                                       cacheCreation: tokens["cacheCreation"]?.double ?? 0)
            proxy.activeContext = tokens["activeContext"]?.double
        }
        return (snapshots, proxy)
    }

    public enum ParseError: Error {
        case notAnObject
    }

    static func claudeAccount(name: String, account: JSONValue, probe: JSONValue?, current: String?,
                              threshold: Double, config: AppConfig) -> AccountSnapshot {
        let quota = account["quota"] ?? .object([:])
        var snapshot = AccountSnapshot(id: name, provider: .claude)
        let forecasts = quota["forecast"]

        func forecast(_ key: String) -> Forecast? {
            guard let entry = forecasts?[key], entry.object != nil else { return nil }
            let rate = entry["ratePerHour"]?.double.map { $0 * 100 }
            return Forecast(ratePerHour: rate, reachesThresholdAt: date(fromMillis: entry["reachesThresholdAt"]),
                            threshold: (entry["threshold"]?.double ?? threshold / 100) * 100)
        }

        switch sessionWindow(quota: quota, configuredNoLimit: config.noFiveHourLimit(name)) {
        case .present:
            snapshot.windows.append(LimitWindow(id: "5h", title: "5-hour", used: percent(quota["unified5h"]),
                                                resetsAt: date(fromMillis: quota["unified5hReset"]),
                                                duration: fiveHours, forecast: forecast("unified5h")))
        case .absent(let note):
            snapshot.sessionNote = note
        }
        snapshot.windows.append(LimitWindow(id: "7d", title: "Weekly", used: percent(quota["unified7d"]),
                                            resetsAt: date(fromMillis: quota["unified7dReset"]),
                                            duration: week, forecast: forecast("unified7d")))
        for (model, scoped) in (quota["scopedWeekly"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            let key = "unified7d" + model.prefix(1).uppercased() + model.dropFirst()
            snapshot.windows.append(LimitWindow(id: "7d.\(model)", title: "\(model.capitalized) weekly",
                                                used: percent(scoped["utilization"]),
                                                resetsAt: date(fromMillis: scoped["resetAt"]),
                                                duration: week, forecast: forecast(key)))
        }

        snapshot.fetchedAt = quotaFetchedAt(quota: quota, probe: probe)
        snapshot.warning = probeWarning(probe?["error"]?.text)
        if let spend = quota["spend"], spend.object != nil {
            snapshot.extraUsage = spend["enabled"]?.bool
            snapshot.spend = spendText(spend)
        }
        snapshot.resets = resetCredits(quota["resetCredits"])
        snapshot.routing = name == current
        snapshot.sessions = account["sessions"]?.int ?? 0
        snapshot.knownSessions = account["knownSessions"]?.int ?? 0
        snapshot.unavailable = account["unavailable"]?.text
        snapshot.status = account["status"]?.string
        snapshot.signIn = signIn(name: name, account: account, holder: .teamclaude)
        snapshot.recentRequests = account["recentRequests"]?.int ?? 0
        if let usage = account["usage"] {
            snapshot.totalRequests = usage["totalRequests"]?.int ?? 0
            snapshot.lastUsed = usage["lastUsed"]?.string.flatMap(isoDate) ?? date(fromMillis: usage["lastUsed"])
            snapshot.tokens = TokenTotals(input: usage["totalInputTokens"]?.double ?? 0,
                                          output: usage["totalOutputTokens"]?.double ?? 0,
                                          cacheRead: usage["totalCacheReadTokens"]?.double ?? 0,
                                          cacheCreation: usage["totalCacheCreationTokens"]?.double ?? 0)
            let models = usage["recentModels"]?.object ?? [:]
            snapshot.recentModels = models.sorted { ($0.value.double ?? 0) > ($1.value.double ?? 0) }.map(\.key)
        }
        return snapshot
    }

    /// An OAuth account's sign-in: when it lapses, where the proxy states it, and why it is refused once
    /// the proxy has put the account in `error`. An API key has no sign-in.
    static func signIn(name: String, account: JSONValue, holder: SignIn.Holder) -> SignIn? {
        guard account["type"]?.string == "oauth" else { return nil }
        // A long-lived token has no refresh token: the token itself lapses, at `expiresAt`.
        let longLived = account["longLived"]?.bool == true
        var signIn = SignIn(holder: holder, account: name,
                            expiresAt: date(fromMillis: account[longLived ? "expiresAt" : "refreshTokenExpiresAt"]),
                            manual: longLived)
        if account["status"]?.string == "error" {
            let reason = account["errorReason"]
            signIn.failure = SignIn.Failure(code: reason?["code"]?.string ?? "error",
                                            detail: reason?["detail"]?.string ?? "The proxy took it out of rotation",
                                            since: date(fromMillis: reason?["since"]), link: reason?["link"]?.string)
        }
        return signIn
    }

    enum SessionWindow: Equatable {
        case present
        case absent(SessionWindowNote)
    }

    /// Whether to show a 5-hour window. An explicit `sessionWindowStated` wins. A
    /// 5-hour reading counts only while it keeps arriving with the weekly one: when
    /// the weekly reading is fresh and the 5-hour one is more than a window older,
    /// the subscription stopped reporting it. A missing counter alone is not proof.
    static func sessionWindow(quota: JSONValue, configuredNoLimit: Bool) -> SessionWindow {
        if let stated = quota["sessionWindowStated"]?.bool {
            return stated ? .present : .absent(.noLimit)
        }
        let hasReading = quota["unified5h"]?.double != nil || quota["unified5hReset"]?.double != nil
        if hasReading {
            if let seen5h = date(fromMillis: quota["unified5hSeenAt"]),
               let seen7d = date(fromMillis: quota["unified7dSeenAt"]),
               seen7d.timeIntervalSince(seen5h) > fiveHours {
                return .absent(configuredNoLimit ? .noLimit : .notReportedSince(seen5h))
            }
            return .present
        }
        return configuredNoLimit ? .absent(.noLimit) : .present
    }

    /// The proxy reports counts only; it keeps the ids it would spend to itself.
    static func resetCredits(_ value: JSONValue?) -> ResetCredits? {
        guard let value, let available = value["available"]?.int, available > 0 else { return nil }
        return ResetCredits(available: available, usableNow: value["applicable"]?.int,
                            fableOnly: min(available, value["fable"]?.int ?? 0),
                            nextExpiry: date(fromMillis: value["expiresAt"]), seenAt: date(fromMillis: value["seenAt"]))
    }

    static func percent(_ value: JSONValue?) -> Double? {
        value?.double.map { ($0 * 10_000).rounded() / 100 }
    }

    /// A failed probe is an attempt, not a fresh observation of quota.
    static func quotaFetchedAt(quota: JSONValue, probe: JSONValue?) -> Date? {
        var seen: [Date] = []
        for (key, value) in quota.object ?? [:] where key.hasSuffix("SeenAt") {
            let base = String(key.dropLast("SeenAt".count))
            if quota[base]?.double != nil, let date = date(fromMillis: value) { seen.append(date) }
        }
        if probe?["status"]?.string == "ok", let probed = probe?["lastProbedAt"]?.string.flatMap(isoDate) {
            seen.append(probed)
        }
        return seen.max()
    }

    static func probeWarning(_ error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        if error.contains("429") { return "Usage check rate-limited; values update with traffic" }
        return "Usage check failed: \(error.prefix(60))"
    }

    static let currencySymbols = ["EUR": "€", "USD": "$", "GBP": "£"]

    static func spendText(_ spend: JSONValue) -> String? {
        let exponent = Double(spend["exponent"]?.int ?? 2)
        let code = spend["currency"]?.string ?? ""
        let symbol = currencySymbols[code] ?? (code.isEmpty ? "" : code + " ")
        func money(_ minor: Double) -> String { symbol + String(format: "%.2f", minor / pow(10, exponent)) }
        var parts: [String] = []
        if let used = spend["usedMinor"]?.double {
            if let limit = spend["limitMinor"]?.double {
                parts.append("\(money(used)) of \(money(limit))")
            } else {
                parts.append("\(money(used)) spent")
            }
        }
        if let reason = spend["disabledReason"]?.string {
            parts.append(reason.replacingOccurrences(of: "_", with: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
