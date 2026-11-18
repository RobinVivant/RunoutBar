import Foundation

/// One banked Claude reset, as Anthropic lists it for the account.
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

    /// The handle a spend names. Kept in memory only; never logged or saved.
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
}

/// An account's reset status, read from Anthropic through the helper.
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

    /// A spend may name a reset from a reading this recent; Anthropic checks the claim itself.
    public func isFresh(at now: Date) -> Bool { now.timeIntervalSince(readAt) <= ClaudeResets.claimTTL }

    /// Why this reset cannot be spent, or nil when it can.
    public func blocked(_ grant: ClaudeResetGrant, now: Date) -> String? {
        if !eligible { return "Not eligible" + (ineligibleReason.map { " (\(ClaudeResets.words($0)))" } ?? "") }
        if grant.resetsLeft < 1 { return "None left" }
        if grant.paused { return "Paused" }
        if !grant.usableNow {
            return "Not usable now" + (grant.unavailableReason.map { " (\(ClaudeResets.words($0)))" } ?? "")
        }
        if let ends = grant.endsAt, ends <= now { return "Expired" }
        return nil
    }

    /// Reasons a spend may be wasted or refused. They do not prevent it.
    public func warnings(_ grant: ClaudeResetGrant, now: Date) -> [String] {
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

/// Reads and spends banked Claude resets. TeamClaude offers this only in the dashboard of a
/// server started in a terminal, so a small Node script loads TeamClaude's own modules from its
/// install and calls the same functions, with the token TeamClaude stores. The token stays in
/// that child process: the script prints reset details and verdicts, nothing else.
public enum ClaudeResets {
    public static let claimTTL: TimeInterval = 15 * 60

    /// A request that produced no verdict.
    public struct Failure: LocalizedError, Equatable, RateLimitError {
        public var message: String
        /// When Anthropic asked the caller to come back.
        public var retryAt: Date?
        /// True when a spend request may have reached Anthropic, so the reset may be spent.
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
        /// Anthropic answered and spent nothing.
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

    /// The helper answers with one JSON line; anything a loaded module prints goes to stderr.
    static func answer(_ result: ProcessResult) -> JSONValue? {
        guard let line = result.output.split(separator: "\n").last(where: { $0.hasPrefix("{") }) else { return nil }
        return try? JSONValue.parse(Data(line.utf8))
    }

    public static func parseStatus(_ answer: JSONValue, now: Date) throws -> ClaudeResetStatus {
        guard answer["ok"]?.bool == true else {
            let message = answer["error"]?.string ?? "No answer from the reset helper"
            let limited = answer["status"]?.int == 429
            throw Failure(message: limited ? "Anthropic rate-limited the read" : message,
                          retryAt: date(fromMillis: answer["retryAt"]), rateLimited: limited)
        }
        let next = answer["nextGrantId"]?.string
        let grants = (answer["grants"]?.array ?? []).compactMap { grant -> ClaudeResetGrant? in
            guard let id = grant["id"]?.string, !id.isEmpty else { return nil }
            return ClaudeResetGrant(
                id: id, kind: ClaudeResetGrant.Kind(rawValue: grant["kind"]?.string ?? "") ?? .weekly,
                label: grant["label"]?.string, resetsLeft: grant["resetsLeft"]?.int ?? 0,
                resetsTotal: grant["resetsTotal"]?.int, clears: grant["clears"]?.array?.compactMap(\.string) ?? [],
                endsAt: date(fromMillis: grant["endsAt"]), usableNow: grant["usableNow"]?.bool == true,
                paused: grant["paused"]?.bool == true, useRequiresLimit: grant["useRequiresLimit"]?.bool,
                unavailableReason: grant["unavailableReason"]?.string, isNext: id == next)
        }
        return ClaudeResetStatus(
            eligible: answer["eligible"]?.bool == true, ineligibleReason: answer["ineligibleReason"]?.string,
            atLimit: answer["atLimit"]?.bool == true, exhausted: answer["exhausted"]?.array?.compactMap(\.string) ?? [],
            cooldownUntil: date(fromMillis: answer["cooldownUntil"]), weeklyResetsAt: date(fromMillis: answer["weeklyResetsAt"]),
            grants: grants.sorted { ($0.endsAt ?? .distantFuture, $0.id) < ($1.endsAt ?? .distantFuture, $1.id) },
            readAt: now)
    }

    /// Only an answer Anthropic is known to give counts as a verdict. Anything else, including
    /// an HTTP error on the spend request, leaves the reset possibly spent.
    public static func parseClaim(_ answer: JSONValue?) throws -> Verdict {
        guard let answer else { throw Failure(message: "No answer from the reset helper", sent: true) }
        guard answer["ok"]?.bool == true else {
            let limited = answer["status"]?.int == 429
            throw Failure(message: limited ? "Anthropic rate-limited the request" : answer["error"]?.string ?? "The spend request failed",
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

    static func packageDir(installDir: String) -> String {
        AppConfig.expand(installDir) + "/node_modules/@karpeleslab/teamclaude"
    }

    static func arguments(installDir: String, _ rest: [String]) -> [String] {
        ["--input-type=module", "-e", script, packageDir(installDir: installDir)] + rest
    }

    /// Read one account's resets from Anthropic. Spends nothing.
    public static func list(node: String, installDir: String, account: String, environment: [String: String],
                            now: Date = Date(), timeout: TimeInterval = 30) async throws -> ClaudeResetStatus {
        let result = try await Shell.run(AppConfig.expand(node), arguments(installDir: installDir, ["list", account]),
                                         environment: environment, timeout: timeout)
        guard let answer = answer(result) else {
            throw Failure(message: result.timedOut ? "Reading resets timed out" : "The reset helper failed: \(result.tail(1))")
        }
        return try parseStatus(answer, now: now)
    }

    /// Spend one reset. This cannot be undone. A thrown `Failure` with `sent` is no verdict: the
    /// reset may be spent, so retry that attempt with the same `requestID`.
    public static func claim(node: String, installDir: String, account: String, grantID: String, requestID: String,
                             environment: [String: String], timeout: TimeInterval = 45) async throws -> Verdict {
        let result = try await Shell.run(AppConfig.expand(node),
                                         arguments(installDir: installDir, ["claim", account, grantID, requestID]),
                                         environment: environment, timeout: timeout)
        return try parseClaim(answer(result))
    }

    /// Runs as `node --input-type=module -e <script> <teamclaude package dir> list|claim <account> [grant request]`.
    /// It never refreshes a token: TeamClaude rotates refresh tokens, and a second refresher would
    /// sign the account out of the proxy.
    static let script = #"""
    import { writeSync } from 'node:fs';
    import { pathToFileURL } from 'node:url';
    import { join } from 'node:path';

    // stdout carries the one JSON answer; whatever the loaded modules print goes to stderr.
    console.log = console.error;
    const [dir, action, name, grantId, requestId] = process.argv.slice(1);
    let sent = false;
    const out = answer => { writeSync(1, JSON.stringify(answer) + '\n'); process.exit(0); };
    const fail = (error, extra = {}) => out({ ok: false, error: String(error).slice(0, 200), sent, ...extra });
    process.on('unhandledRejection', err => fail(err?.message || err));

    try {
      const load = file => import(pathToFileURL(join(dir, 'src', file)).href);
      const [config, resolve, provider, resets] = await Promise.all(
        ['config.js', 'resolve-accounts.js', 'provider.js', 'claude-resets.js'].map(load));
      for (const [mod, fn] of [[config, 'loadConfig'], [resolve, 'resolveAccounts'], [provider, 'providerOf'],
        [resets, 'fetchClaudeResetStatus'], [resets, 'claimClaudeReset'], [resets, 'claudeGrantKind']]) {
        if (typeof mod[fn] !== 'function') fail(`this TeamClaude version has no ${fn}`);
      }

      const settings = await config.loadConfig();
      if (!settings) fail('TeamClaude config not found');
      // Only this account is resolved, so no other account's credentials are read.
      const named = (settings.accounts ?? []).filter(a => a?.name === name && a.type === 'oauth'
        && provider.providerOf(a) === provider.DEFAULT_PROVIDER && !a.upstream);
      if (named.length !== 1) fail(named.length ? 'more than one Claude account has this name' : 'no Claude account has this name');
      const [stored] = await resolve.resolveAccounts({ ...settings, accounts: named });
      if (!stored) fail('account has no usable token');
      if (stored.disabled) fail('account is disabled');
      if (stored.longLived === true) fail('a long-lived token cannot read or spend resets');
      if (!stored.accessToken || !stored.orgUuid) fail('account has no token or organization id');
      if (Number.isFinite(stored.expiresAt) && stored.expiresAt <= Date.now() + 30_000) {
        fail('the stored token has expired; TeamClaude renews it with the next request on this account');
      }

      // An account with its own egress proxy must not be reached by another path.
      let routing = null;
      if (stored.routing) {
        const [manager, upstream] = await Promise.all([load('account-manager.js'), load('upstream-proxy.js')]);
        routing = manager.accountRouting?.(stored, upstream.localListener?.(settings) ?? null) ?? null;
        if (!routing) fail('could not resolve this account\'s routing proxy');
      }
      const account = { ...stored, credential: stored.accessToken, routing };

      if (action === 'list') {
        const read = await resets.fetchClaudeResetStatus(account, { timeoutMs: 15_000 });
        if (read?.error) fail(read.error, { status: read.status ?? null, retryAt: read.retryAt ?? null });
        const status = read?.reset;
        if (!status) fail('Anthropic returned no reset status');
        out({
          ok: true, eligible: status.eligible, ineligibleReason: status.ineligibleReason, atLimit: status.atLimit,
          exhausted: status.exhausted, cooldownUntil: status.cooldownUntil, weeklyResetsAt: status.weeklyResetsAt,
          nextGrantId: status.nextGrantId,
          grants: status.grants.map(g => ({
            id: g.id, kind: resets.claudeGrantKind(g), label: g.label, resetsLeft: g.resetsLeft,
            resetsTotal: g.resetsTotal, clears: g.clears, endsAt: g.endsAt, usableNow: g.usableNow, paused: g.paused,
            useRequiresLimit: g.useRequiresLimit, unavailableReason: g.unavailableReason,
          })),
        });
      } else if (action === 'claim') {
        if (!/^[a-z0-9_-]{1,40}$/.test(grantId || '') || !/^[A-Za-z0-9_-]{1,64}$/.test(requestId || '')) {
          fail('malformed reset or request id');
        }
        sent = true;
        const claim = await resets.claimClaudeReset(account, { grantId, requestId }, { timeoutMs: 20_000 });
        // An answer without `status` was refused before any request left.
        if (claim?.error) fail(claim.error, { sent: 'status' in claim, status: claim.status ?? null, retryAt: claim.retryAt ?? null });
        out({
          ok: true, result: claim.result ?? null, reason: claim.reason ?? null, resetsLeft: claim.resetsLeft ?? null,
          cleared: claim.cleared ?? [], cooldownUntil: claim.cooldownUntil ?? null,
        });
      } else {
        fail('unknown action');
      }
    } catch (err) {
      fail(err?.message || err);
    }
    """#
}
