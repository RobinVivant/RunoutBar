import Foundation

/// Codex limits and banked resets through `codex app-server --stdio`
/// (`account/rateLimits/read`, `account/rateLimitResetCredit/consume`).
/// The app server handles the login; this process never sees a credential.
public enum Codex {
    public static func parse(_ data: Data, now: Date = Date()) throws -> AccountSnapshot {
        let result = try JSONValue.parse(data)
        var snapshot = AccountSnapshot(id: AppConfig.codexKey, provider: .codex)
        var buckets = result["rateLimitsByLimitId"]?.object ?? [:]
        if buckets.isEmpty, let single = result["rateLimits"] { buckets = ["codex": single] }

        for (bucketID, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            let prefix = bucketID == "codex" ? "" : (bucket["limitName"]?.string ?? bucketID) + " "
            let idPrefix = bucketID == "codex" ? "" : "\(bucketID)."
            for key in ["primary", "secondary"] {
                guard let window = bucket[key], window.object != nil else { continue }
                let minutes = window["windowDurationMins"]?.int
                let (id, title): (String, String)
                switch minutes {
                case 300: (id, title) = ("5h", "5-hour")
                case 10080: (id, title) = ("7d", "Weekly")
                case .some(let m): (id, title) = ("\(m)m", "\(m) minutes")
                case .none: (id, title) = (key, key.capitalized)
                }
                let resets = window["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) }
                snapshot.windows.append(LimitWindow(id: idPrefix + id, title: prefix + title,
                                                    used: window["usedPercent"]?.double, resetsAt: resets,
                                                    duration: minutes.map { TimeInterval($0 * 60) }))
            }
            if snapshot.plan == nil { snapshot.plan = bucket["planType"]?.string.map(planName) }
        }
        // Short windows first, as for Claude.
        snapshot.windows.sort { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }
        snapshot.blocked = result["ordinaryUsageAllowed"]?.bool == false
        snapshot.resets = resetCredits(result["rateLimitResetCredits"], now: now)
        snapshot.fetchedAt = now
        if snapshot.windows.isEmpty { snapshot.error = "No limits reported" }
        return snapshot
    }

    /// The server may list fewer credits than it counts, or none at all.
    static func resetCredits(_ value: JSONValue?, now: Date) -> ResetCredits? {
        guard let value, value.object != nil else { return nil }
        let grants = value["credits"]?.array?.compactMap { credit -> ResetGrant? in
            guard let id = credit["id"]?.string, !id.isEmpty else { return nil }
            return ResetGrant(id: id, title: credit["title"]?.string,
                              grantedAt: credit["grantedAt"]?.double.map { Date(timeIntervalSince1970: $0) },
                              expiresAt: credit["expiresAt"]?.double.map { Date(timeIntervalSince1970: $0) },
                              available: credit["status"]?.string == "available")
        }
        let listed = grants?.filter { $0.available && ($0.expiresAt.map { $0 > now } ?? true) } ?? []
        let available = max(value["availableCount"]?.int ?? 0, listed.count)
        guard available > 0 else { return nil }
        return ResetCredits(available: available, nextExpiry: listed.compactMap(\.expiresAt).min(), seenAt: now,
                            grants: grants.map { _ in listed.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) } })
    }

    /// What the server answered to a redeem request.
    public enum ResetOutcome: String, Sendable {
        /// A credit was spent and the eligible windows were reset.
        case reset
        /// No window is eligible; nothing was spent.
        case nothingToReset
        /// The account holds no credit; nothing was spent.
        case noCredit
        /// This idempotency key already completed a reset.
        case alreadyRedeemed

        public var spent: Bool { self == .reset || self == .alreadyRedeemed }
    }

    public static func parseResetOutcome(_ data: Data) throws -> ResetOutcome {
        let raw = try JSONValue.parse(data)["outcome"]?.string
        guard let raw, let outcome = ResetOutcome(rawValue: raw) else {
            throw CodexError.requestFailed("unexpected answer \(raw ?? "without an outcome")")
        }
        return outcome
    }

    static func consumeParams(creditID: String?, idempotencyKey: String) -> [String: Any] {
        var params: [String: Any] = ["idempotencyKey": idempotencyKey]
        if let creditID { params["creditId"] = creditID }
        return params
    }

    /// Spend one banked reset. This cannot be undone. `creditID` nil lets the server pick. A thrown
    /// error is no verdict: the credit may be spent, so retry that attempt with the same key.
    public static func consumeResetCredit(codex: String, environment: [String: String], creditID: String?,
                                          idempotencyKey: String, timeout: TimeInterval = 40) async throws -> ResetOutcome {
        let data = try await call(codex: codex, environment: environment, method: "account/rateLimitResetCredit/consume",
                                  params: consumeParams(creditID: creditID, idempotencyKey: idempotencyKey),
                                  timeout: timeout)
        return try parseResetOutcome(data)
    }

    /// What a failed read says about the Codex login, or nil when the failure is about something else.
    /// The read does not say when the login stopped working, so the failure carries no time.
    public static func signInFailure(_ error: Error) -> SignIn.Failure? {
        guard case CodexError.requestFailed(let message) = error else { return nil }
        let text = message.lowercased()
        // "chatgpt authentication required" is an API-key login, which has no limits to read and is no lapse.
        if text.contains("codex account authentication required") {
            return SignIn.Failure(code: "signed_out", detail: "The Codex CLI is not signed in")
        }
        let refused = ["could not be refreshed", "sign in again", "401", "unauthorized"]
        guard refused.contains(where: text.contains) else { return nil }
        // Keep the server's sentence, without the prefix of the call and the advice that follows.
        var detail = message
        if let range = detail.range(of: "rate limits: ") { detail = String(detail[range.upperBound...]) }
        if let stop = detail.range(of: ". ") { detail = String(detail[..<stop.lowerBound]) }
        return SignIn.Failure(code: "refresh_rejected", detail: detail.trimmingCharacters(in: .whitespaces))
    }

    static func planName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "self_serve_", with: "")
            .split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Candidate locations when the config does not name one.
    public static func locate(configured: String?) -> String? {
        if let configured {
            return configured.isEmpty ? nil : AppConfig.expand(configured)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Start an isolated app server, read the limits, and stop it.
    public static func fetchRateLimits(codex: String, environment: [String: String],
                                       timeout: TimeInterval = 25) async throws -> Data {
        try await call(codex: codex, environment: environment, method: "account/rateLimits/read", params: nil,
                       timeout: timeout)
    }

    /// One request against a fresh app server, which is stopped afterwards.
    static func call(codex: String, environment: [String: String], method: String, params: [String: Any]?,
                     timeout: TimeInterval) async throws -> Data {
        let body = try params.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).async {
                once.resume(Result {
                    try callBlocking(codex: codex, environment: environment, method: method, params: body,
                                     timeout: timeout)
                })
            }
            // Last resort when a read outlives the app server (a grandchild holding its stdout).
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + Shell.killGrace + 2) {
                once.resume(.failure(CodexError.timedOut))
            }
        }
    }

    public enum CodexError: LocalizedError {
        case closed, requestFailed(String), timedOut

        public var errorDescription: String? {
            switch self {
            case .closed: return "Codex app server closed the connection"
            case .requestFailed(let message): return "Codex request failed: \(message)"
            case .timedOut: return "Codex app server timed out"
            }
        }
    }

    static func callBlocking(codex: String, environment: [String: String], method: String, params: Data?,
                             timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server", "--stdio"]
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        let watchdog = DispatchWorkItem { Shell.stop(process) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            Shell.stop(process)  // escalates to SIGKILL, so the wait below ends
            process.waitUntilExit()
        }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        var buffer = Data()
        func receive(_ id: Int) throws -> Any? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (message["id"] as? Int) == id else { continue }
                    if let error = message["error"] {
                        let text = (error as? [String: Any])?["message"] as? String ?? "\(error)"
                        throw CodexError.requestFailed(text)
                    }
                    return message["result"]
                }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { throw Date() >= deadline ? CodexError.timedOut : CodexError.closed }
                buffer.append(chunk)
            }
        }

        try send(["id": 1, "method": "initialize",
                  "params": ["clientInfo": ["name": "runout_bar", "version": "1.0"]]])
        _ = try receive(1)
        try send(["method": "initialized", "params": [String: Any]()])
        var request: [String: Any] = ["id": 2, "method": method]
        if let params { request["params"] = try JSONSerialization.jsonObject(with: params) }
        try send(request)
        let result = try receive(2) ?? [String: Any]()
        return try JSONSerialization.data(withJSONObject: result)
    }
}
