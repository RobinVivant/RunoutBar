import Foundation

/// A sign-in that readings and routing depend on: a TeamClaude account's OAuth login, or the Codex CLI's own.
/// A provider ends a sign-in after a fixed time, and the account then stops answering until someone signs in again.
public struct SignIn: Identifiable, Sendable, Hashable {
    /// Who keeps the sign-in, which decides the command that renews it.
    public enum Holder: String, Sendable, Hashable {
        /// A Claude account in TeamClaude.
        case teamclaude
        /// A Codex account in TeamClaude, apart from the Codex CLI's login.
        case teamclaudeCodex
        /// The Codex CLI's login, which the app server reads limits with.
        case codex
    }

    /// Why the provider refuses the sign-in.
    public struct Failure: Sendable, Hashable {
        public var code: String
        public var detail: String
        public var since: Date?
        /// Where the provider says to resolve it, when it gives a link.
        public var link: String?

        public init(code: String, detail: String, since: Date? = nil, link: String? = nil) {
            self.code = code
            self.detail = detail
            self.since = since
            self.link = link
        }

        /// A new sign-in alone brings the account back. Other codes are about the account itself, such as one
        /// on hold, and need resolving at the provider first.
        public var fixedBySigningIn: Bool { ["refresh_rejected", "credential_rejected", "signed_out"].contains(code) }
    }

    /// How close the sign-in is to stopping, in rising order of urgency.
    public enum Stage: Int, Codable, Sendable, Comparable {
        case ok, soon, urgent, lapsed

        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    public var holder: Holder
    /// The account's name at the holder.
    public var account: String
    /// When the sign-in lapses, where the holder states it.
    public var expiresAt: Date?
    public var failure: Failure?
    /// The renewal needs a code pasted into a terminal, so the app shows the command instead of running it.
    public var manual = false

    public init(holder: Holder, account: String, expiresAt: Date? = nil, failure: Failure? = nil, manual: Bool = false) {
        self.holder = holder
        self.account = account
        self.expiresAt = expiresAt
        self.failure = failure
        self.manual = manual
    }

    public var id: String { "\(holder.rawValue):\(account)" }

    /// A sign-in is announced this far ahead of its end, as TeamClaude's own log does.
    public static let warnAhead: TimeInterval = 5 * 86_400
    public static let urgentAhead: TimeInterval = 86_400

    public func stage(at now: Date) -> Stage {
        if failure != nil { return .lapsed }
        guard let expiresAt else { return .ok }
        let left = expiresAt.timeIntervalSince(now)
        if left <= 0 { return .lapsed }
        if left <= Self.urgentAhead { return .urgent }
        return left <= Self.warnAhead ? .soon : .ok
    }

    /// A few words for a row or a notification: "Sign-in expires in 18h".
    public func headline(now: Date) -> String {
        if let failure {
            if failure.code == "signed_out" { return "Not signed in" }
            return failure.fixedBySigningIn || failure.code == "error" ? "Sign-in rejected" : "Account refused"
        }
        guard let expiresAt else { return "Signed in" }
        switch stage(at: now) {
        case .lapsed: return "Sign-in expired"
        case .soon, .urgent: return "Sign-in expires in \(Format.duration(expiresAt.timeIntervalSince(now)))"
        case .ok: return "Signed in until \(Self.when(expiresAt, now: now))"
        }
    }

    /// One sentence on what happened or will happen, and when.
    public func explanation(now: Date) -> String {
        if let failure {
            let detail = Self.sentence(failure.detail)
            if !failure.fixedBySigningIn, failure.code != "error" {
                return "\(detail) Resolve it with the provider, then sign in again."
            }
            guard let since = failure.since else { return detail }
            return "Rejected \(Self.when(since, now: now)): \(detail)"
        }
        guard let expiresAt else { return "The provider states no end date for this sign-in." }
        let date = Self.when(expiresAt, now: now)
        switch stage(at: now) {
        case .lapsed:
            return "Expired \(date). It leaves rotation at its next token refresh and its readings stop."
        case .soon, .urgent:
            return "Expires \(date), then it leaves rotation and its readings stop."
        case .ok:
            return "Good until \(date). Signing in again starts a new period."
        }
    }

    /// Text that ends as a sentence, whatever the source gave.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "No reason given." }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    /// The arguments that renew the sign-in, after the holder's executable.
    public var loginArguments: [String] {
        switch holder {
        // `--oauth` is the browser login; without it the command asks a terminal which kind to run.
        case .teamclaude: return manual ? ["login", "--long-lived", "--name", account] : ["login", "--oauth"]
        case .teamclaudeCodex: return ["login", "--codex"]
        case .codex: return ["login"]
        }
    }

    /// The command as someone would type it.
    public var commandLine: String {
        switch holder {
        case .teamclaude: return manual ? "teamclaude login --long-lived --name \(account)" : "teamclaude login"
        case .teamclaudeCodex: return "teamclaude login --codex"
        case .codex: return "codex login"
        }
    }

    /// A date within the week as "Fri 10:54", a later one as "Sat 19 Dec".
    static func when(_ date: Date, now: Date) -> String {
        abs(date.timeIntervalSince(now)) < 6 * 86_400 ? Format.dayTime(date) : Format.day(date)
    }
}

/// What a sign-in command changed, read from the sign-ins before and after it.
public enum Reconnect {
    public enum Outcome: Sendable, Equatable {
        /// The sign-in that was asked for is fresh.
        case renewed(until: Date?)
        /// The browser was signed in to other accounts, which were renewed or added instead.
        case renewedOther([String])
        case unchanged
    }

    public static func outcome(target: SignIn, before: [SignIn], after: [SignIn], succeeded: Bool) -> Outcome {
        let earlier = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        /// The sign-in shows it was renewed: its refusal is gone, or its end moved out.
        func renewed(_ now: SignIn) -> Bool {
            guard now.failure == nil, let was = earlier[now.id] else { return false }
            if was.failure != nil { return true }
            guard let end = now.expiresAt, let previous = was.expiresAt else { return false }
            return end.timeIntervalSince(previous) > 60
        }
        let current = after.first { $0.id == target.id }
        if let current, renewed(current) { return .renewed(until: current.expiresAt) }
        let others = after.filter { $0.holder == target.holder && $0.id != target.id }
            .filter { renewed($0) || (earlier[$0.id] == nil && $0.failure == nil) }
        if !others.isEmpty { return .renewedOther(others.map(\.account)) }
        // Without a date there is nothing to compare: a command that succeeded on a sign-in nobody refuses.
        // One that was listed neither before nor after, as the account a first login was to add, shows nothing.
        guard succeeded, current != nil || earlier[target.id] != nil else { return .unchanged }
        let undated = (current ?? target).expiresAt == nil && target.failure == nil && current?.failure == nil
        return undated ? .renewed(until: nil) : .unchanged
    }

    /// The reason a failed login command gave, without the links and alternatives around it.
    public static func failureReason(_ output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            if let range = line.range(of: "login failed: ", options: .caseInsensitive) {
                return String(line[range.upperBound...])
            }
        }
        // A login link carries its one-time state, and has no place in a message.
        return lines.first { ($0.hasPrefix("Could not") || $0.hasPrefix("Error")) && !$0.contains("://") }
    }
}
