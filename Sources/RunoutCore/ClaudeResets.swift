import Foundation

/// One banked Claude reset, as the proxy's control routes or Anthropic list it for the account.
public struct ClaudeResetGrant: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable {
        case weekly, fable, session

        public var title: String {
            switch self {
            case .weekly: return "Weekly"
            case .fable: return "Fable"
            case .session: return "Session"
            }
        }
    }

    /// The in-memory handle a spend names.
    public var id: String
    public var kind: Kind
    public var label: String?
    public var resetsLeft: Int
    public var resetsTotal: Int?
    /// Upstream limit names this reset clears, such as `seven_day`.
    public var clears: [String]
    public var endsAt: Date?
    public var usableNow: Bool
    public var paused: Bool
    /// Whether Anthropic says the limit must be reached first; nil when it does not say.
    public var useRequiresLimit: Bool?
    public var unavailableReason: String?
    /// The one Anthropic would spend next.
    public var isNext: Bool
    /// Server-computed block reason from `/teamclaude/resets*`, or nil when usable or absent.
    public var serverBlocked: String? = nil
    /// Server-computed warnings from `/teamclaude/resets*`; nil for legacy/demo statuses.
    public var serverWarnings: [String]? = nil
}

/// An account's reset status, read from the running proxy's control routes.
public struct ClaudeResetStatus: Sendable, Hashable {
    public var eligible: Bool
    public var ineligibleReason: String?
    public var atLimit: Bool
    /// Upstream limit names that are exhausted right now.
    public var exhausted: [String]
    public var cooldownUntil: Date?
    public var weeklyResetsAt: Date?
    public var grants: [ClaudeResetGrant]
    public var readAt: Date
    public var readableAt: Date? = nil
    public var stale = false
    public var error: String? = nil
    public var fleetHoldUntil: Date? = nil

    /// A spend may name a reset from a reading this recent; the server checks the claim itself.
    public func isFresh(at now: Date) -> Bool { now.timeIntervalSince(readAt) <= ClaudeResets.claimTTL }

    /// Why this reset cannot be spent, or nil when it can.
    public func blocked(_ grant: ClaudeResetGrant, now: Date) -> String? {
        if let serverBlocked = grant.serverBlocked { return serverBlocked }
        if let ends = grant.endsAt, ends <= now { return "Expired" }
        if grant.serverWarnings != nil {
            return grant.resetsLeft < 1 ? "None left" : nil
        }
        if !eligible { return "Not eligible" + (ineligibleReason.map { " (\(ClaudeResets.words($0)))" } ?? "") }
        if grant.resetsLeft < 1 { return "None left" }
        if grant.paused { return "Paused" }
        if !grant.usableNow {
            return "Not usable now" + (grant.unavailableReason.map { " (\(ClaudeResets.words($0)))" } ?? "")
        }
        return nil
    }

    /// Reasons a spend may be wasted or refused. They do not prevent a manual confirmation.
    public func warnings(_ grant: ClaudeResetGrant, now: Date) -> [String] {
        if let serverWarnings = grant.serverWarnings { return serverWarnings }
        var warnings: [String] = []
        if !atLimit, grant.useRequiresLimit != false {
            warnings.append("This account is not at a usage limit. Anthropic may still accept, and the reset is then spent.")
        }
        if !exhausted.contains(where: { $0.hasPrefix("seven_day") }) {
            warnings.append("No weekly limit is exhausted.")
        }
        let uncovered = exhausted.filter { !grant.clears.contains($0) }
        if !uncovered.isEmpty {
            warnings.append("It does not clear \(ClaudeResets.limits(uncovered)), which \(uncovered.count == 1 ? "is" : "are") exhausted.")
        }
        if let cooldown = cooldownUntil, cooldown > now {
            warnings.append("Anthropic reports a reset cooldown until \(Format.dayTime(cooldown)).")
        }
        return warnings
    }
}

/// Reads and spends banked Claude resets through the running proxy's control routes
/// (`GET /teamclaude/resets`, `POST /teamclaude/resets/read`, `POST /teamclaude/resets/redeem`,
/// and their `/teamrouter/...` aliases) without importing internal modules or reading tokens.
public enum ClaudeResets {
    public static let claimTTL: TimeInterval = 15 * 60

    static let apiKeyRequiredMessage =
        "The proxy requires an API key (401). Set \"proxyApiKey\" in ~/.config/runout-bar/config.json."

    /// A request that produced no verdict.
    public struct Failure: LocalizedError, Equatable, RateLimitError {
        public var message: String
        /// When Anthropic asked the caller to come back.
        public var retryAt: Date?
        /// True when a spend request may have reached the proxy/Anthropic, so the reset may be spent.
        public var sent: Bool
        /// Anthropic refused the call for now (HTTP 429). The queue sends it again later.
        public var rateLimited: Bool

        public init(message: String, retryAt: Date? = nil, sent: Bool = false, rateLimited: Bool = false) {
            self.message = message
            self.retryAt = retryAt
            self.sent = sent
            self.rateLimited = rateLimited
        }

        public var errorDescription: String? { message }
    }

    public enum Verdict: Equatable, Sendable {
        /// A reset was spent. `replay` when this request id had already gone through.
        case spent(cleared: [String], resetsLeft: Int?, replay: Bool)
        /// The proxy or Anthropic answered and spent nothing.
        case declined(String)
    }

    /// "seven_day_overage_included" → "Fable weekly".
    static func limitName(_ raw: String) -> String {
        switch raw {
        case "five_hour": return "5-hour"
        case "seven_day": return "weekly"
        case "seven_day_overage_included": return "Fable weekly"
        default: return words(raw)
        }
    }

    /// ["seven_day", "five_hour"] → "the weekly and 5-hour limits".
    public static func limits(_ raw: [String]) -> String {
        let names = raw.map(limitName)
        guard let last = names.last else { return "no limit" }
        if names.count == 1 { return "the \(last) limit" }
        return "the \(names.dropLast().joined(separator: ", ")) and \(last) limits"
    }

    static func words(_ raw: String) -> String { raw.replacingOccurrences(of: "_", with: " ") }

    public static func controlBaseURL(dashboard: String, port: Int? = nil) -> URL? {
        guard let parsed = URL(string: dashboard),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if dashboard == AppConfig().dashboard, let port, (1...65_535).contains(port) {
            components.port = port
        } else {
            components.port = parsed.port
        }
        return components.url
    }

    public static func routePrefix(dashboard: String) -> String {
        if let path = URL(string: dashboard)?.path,
           path == "/teamrouter" || path.hasPrefix("/teamrouter/") {
            return "/teamrouter"
        }
        return "/teamclaude"
    }

    static func endpoint(base: URL, route: String, prefix: String) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let cleanRoute = route.hasPrefix("/") ? String(route.dropFirst()) : route
        components?.path = cleanRoute.isEmpty ? prefix : "\(prefix)/\(cleanRoute)"
        return components?.url
    }

    public static func parseDetails(_ details: JSONValue, readableAt: Date? = nil,
                                    now: Date) throws -> ClaudeResetStatus {
        let ineligibleReason = details["ineligibleReason"]?.string
        let eligible = details["eligible"]?.bool ?? (ineligibleReason == nil)
        let next = details["nextGrantId"]?.string
        let errorText = details["error"]?.string
        let retryAt = date(fromMillis: details["retryAt"])
        let grants = (details["grants"]?.array ?? []).compactMap { grant -> ClaudeResetGrant? in
            guard let id = grant["id"]?.string, !id.isEmpty else { return nil }
            let serverBlocked = grant["blocked"]?.string
            let serverWarnings = grant["warnings"]?.array?.compactMap(\.string)
            let usableNow = grant["usableNow"]?.bool ?? (serverBlocked == nil)
            let paused = grant["paused"]?.bool ?? false
            let isNext = (grant["next"]?.bool == true) || (id == next)
            return ClaudeResetGrant(
                id: id,
                kind: ClaudeResetGrant.Kind(rawValue: grant["kind"]?.string ?? "") ?? .weekly,
                label: grant["label"]?.string,
                resetsLeft: grant["resetsLeft"]?.int ?? 0,
                resetsTotal: grant["resetsTotal"]?.int,
                clears: grant["clears"]?.array?.compactMap(\.string) ?? [],
                endsAt: date(fromMillis: grant["endsAt"]),
                usableNow: usableNow,
                paused: paused,
                useRequiresLimit: grant["useRequiresLimit"]?.bool,
                unavailableReason: grant["unavailableReason"]?.string,
                isNext: isNext,
                serverBlocked: serverBlocked,
                serverWarnings: serverWarnings)
        }
        if let errorText, !errorText.isEmpty, grants.isEmpty {
            let limited = errorText.contains("429") || retryAt != nil
            throw Failure(message: limited ? "Anthropic rate-limited the read" : errorText,
                          retryAt: retryAt ?? readableAt, sent: false, rateLimited: limited)
        }
        let readAt = date(fromMillis: details["seenAt"]) ?? now
        return ClaudeResetStatus(
            eligible: eligible,
            ineligibleReason: ineligibleReason,
            atLimit: details["atLimit"]?.bool == true,
            exhausted: details["exhausted"]?.array?.compactMap(\.string) ?? [],
            cooldownUntil: date(fromMillis: details["cooldownUntil"]),
            weeklyResetsAt: date(fromMillis: details["weeklyResetsAt"]),
            grants: grants.sorted { ($0.endsAt ?? .distantFuture, $0.id) < ($1.endsAt ?? .distantFuture, $1.id) },
            readAt: readAt,
            readableAt: readableAt,
            stale: details["stale"]?.bool == true,
            error: errorText,
            fleetHoldUntil: date(fromMillis: details["fleetHoldUntil"]))
    }

    public static func parseStatus(_ answer: JSONValue, now: Date) throws -> ClaudeResetStatus {
        guard answer["ok"]?.bool == true else {
            let message = answer["error"]?.string ?? "No answer from the proxy"
            let limited = answer["status"]?.int == 429
            throw Failure(message: limited ? "Anthropic rate-limited the read" : message,
                          retryAt: date(fromMillis: answer["retryAt"]), rateLimited: limited)
        }
        if let details = answer["details"], details.object != nil {
            return try parseDetails(details, readableAt: date(fromMillis: answer["readableAt"]), now: now)
        }
        return try parseDetails(answer, readableAt: date(fromMillis: answer["readableAt"]), now: now)
    }

    public static func parseClaim(_ answer: JSONValue?) throws -> Verdict {
        guard let answer else { throw Failure(message: "No answer from the proxy", sent: true) }
        guard answer["ok"]?.bool == true else {
            let limited = answer["status"]?.int == 429
            throw Failure(message: limited ? "Anthropic rate-limited the request"
                          : answer["error"]?.string ?? "The spend request failed",
                          retryAt: date(fromMillis: answer["retryAt"]), sent: answer["sent"]?.bool != false,
                          rateLimited: limited)
        }
        let cleared = answer["cleared"]?.array?.compactMap(\.string) ?? []
        switch answer["result"]?.string {
        case "reset": return .spent(cleared: cleared, resetsLeft: answer["resetsLeft"]?.int, replay: false)
        case "already_used": return .spent(cleared: cleared, resetsLeft: answer["resetsLeft"]?.int, replay: true)
        case let result? where ["not_limited", "cooldown", "ineligible", "unavailable"].contains(result):
            return .declined(words(result) + (answer["reason"]?.string.map { ": \(words($0))" } ?? ""))
        case let other:
            throw Failure(message: "Unexpected answer \(other ?? "without a result")", sent: true)
        }
    }

    static func stripManualPrefix(_ text: String) -> String {
        if let range = text.range(of: #"^Manual reset on "[^"]*":\s*"#, options: .regularExpression) {
            return String(text[range.upperBound...])
        }
        return text
    }

    public static func parseRedeem(status: Int, json: JSONValue?) throws -> Verdict {
        let rawError = json?["error"]?.string ?? json?["error"]?["message"]?.string
        switch status {
        case 200:
            guard json?["ok"]?.bool == true, json?["redeemed"]?.bool == true else {
                throw Failure(message: rawError ?? "Unexpected answer from the proxy", sent: true)
            }
            let cleared = json?["cleared"]?.array?.compactMap(\.string) ?? []
            let left = json?["resetsLeft"]?.int
            let replay = json?["result"]?.string == "already_used"
            return .spent(cleared: cleared, resetsLeft: left, replay: replay)
        case 409:
            let message = stripManualPrefix(rawError ?? "The proxy declined the reset")
            return .declined(message)
        case 502:
            throw Failure(message: rawError ?? "No verdict from Anthropic", sent: true)
        case 401:
            throw Failure(message: apiKeyRequiredMessage, sent: false)
        case 400, 403, 404, 413, 501:
            throw Failure(message: rawError ?? "The proxy refused the request (HTTP \(status))", sent: false)
        default:
            throw Failure(message: rawError ?? "Unexpected proxy response (HTTP \(status))", sent: true)
        }
    }

    /// Read all cached Claude reset listings held in memory by the proxy (`GET /teamclaude/resets`).
    /// Sends no request upstream to Anthropic.
    public static func fetchCached(dashboard: String, port: Int? = nil, apiKey: String? = nil,
                                   session: URLSession = .shared, now: Date = Date(),
                                   timeout: TimeInterval = 15) async throws -> [String: ClaudeResetStatus] {
        let (status, json) = try await requestJSON(
            dashboard: dashboard, port: port, apiKey: apiKey, route: "resets", method: "GET",
            body: nil, session: session, timeout: timeout, sentOnTransportError: false)
        try ensureSuccess(status: status, json: json)
        var result: [String: ClaudeResetStatus] = [:]
        for entry in json?["accounts"]?.array ?? [] {
            guard entry["provider"]?.string == "claude",
                  let name = entry["account"]?.string, !name.isEmpty,
                  let details = entry["details"], details.object != nil else { continue }
            let readable = date(fromMillis: entry["readableAt"])
            if let parsed = try? parseDetails(details, readableAt: readable, now: now) {
                result[name] = parsed
            }
        }
        return result
    }

    /// Read one Claude account's resets through the proxy (`POST /teamclaude/resets/read`). Spends nothing.
    public static func list(dashboard: String, port: Int? = nil, apiKey: String? = nil,
                            account: String, session: URLSession = .shared, now: Date = Date(),
                            timeout: TimeInterval = 30) async throws -> ClaudeResetStatus {
        let (status, json) = try await requestJSON(
            dashboard: dashboard, port: port, apiKey: apiKey, route: "resets/read", method: "POST",
            body: ["account": account], session: session, timeout: timeout, sentOnTransportError: false)
        try ensureSuccess(status: status, json: json)
        guard let details = json?["details"], details.object != nil else {
            throw Failure(message: json?["error"]?.string ?? "The proxy returned no reset status", sent: false)
        }
        return try parseDetails(details, readableAt: date(fromMillis: json?["readableAt"]), now: now)
    }

    /// Spend one banked Claude reset through the proxy (`POST /teamclaude/resets/redeem`). Cannot be undone.
    public static func claim(dashboard: String, port: Int? = nil, apiKey: String? = nil,
                             account: String, grantID: String, session: URLSession = .shared,
                             timeout: TimeInterval = 45) async throws -> Verdict {
        guard grantID.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil else {
            throw Failure(message: "malformed reset id", sent: false)
        }
        let (status, json) = try await requestJSON(
            dashboard: dashboard, port: port, apiKey: apiKey, route: "resets/redeem", method: "POST",
            body: ["account": account, "grantId": grantID], session: session, timeout: timeout,
            sentOnTransportError: true)
        return try parseRedeem(status: status, json: json)
    }

    private static func requestJSON(dashboard: String, port: Int?, apiKey: String?, route: String,
                                    method: String, body: [String: Any]?, session: URLSession,
                                    timeout: TimeInterval, sentOnTransportError: Bool) async throws -> (Int, JSONValue?) {
        guard let base = controlBaseURL(dashboard: dashboard, port: port),
              let url = endpoint(base: base, route: route, prefix: routePrefix(dashboard: dashboard)) else {
            throw Failure(message: "Invalid dashboard URL \"\(dashboard)\"", sent: false)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: error.localizedDescription, sent: sentOnTransportError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: "Invalid response from proxy", sent: sentOnTransportError)
        }
        let parsed = try? JSONValue.parse(data)
        return (http.statusCode, parsed)
    }

    private static func ensureSuccess(status: Int, json: JSONValue?) throws {
        if status == 401 {
            throw Failure(message: apiKeyRequiredMessage, sent: false)
        }
        let message = json?["error"]?.string ?? json?["error"]?["message"]?.string
        let retryAt = date(fromMillis: json?["retryAt"]) ?? date(fromMillis: json?["details"]?["retryAt"])
        if status == 429 {
            throw Failure(message: "Anthropic rate-limited the read", retryAt: retryAt, sent: false, rateLimited: true)
        }
        guard status == 200, json?["ok"]?.bool == true else {
            throw Failure(message: message ?? "The proxy returned HTTP \(status)", retryAt: retryAt, sent: false)
        }
    }
}
