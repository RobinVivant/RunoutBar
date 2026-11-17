import Foundation
import Testing
@testable import UsageCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func millis(_ offset: TimeInterval) -> Double { (now.timeIntervalSince1970 + offset) * 1000 }

private func status(_ json: String) throws -> ClaudeResetStatus {
    try ClaudeResets.parseStatus(JSONValue.parse(Data(json.utf8)), now: now)
}

private func listing(eligible: Bool = true, atLimit: Bool = true, exhausted: String = #"["seven_day"]"#,
                     cooldown: String = "null", grant: String = "") throws -> ClaudeResetStatus {
    try status("""
    {"ok": true, "eligible": \(eligible), "ineligibleReason": \(eligible ? "null" : "\"plan_tier\""),
     "atLimit": \(atLimit), "exhausted": \(exhausted), "cooldownUntil": \(cooldown), "nextGrantId": "g1",
     "grants": [{"id": "g1", "kind": "weekly", "resetsLeft": 2, "resetsTotal": 3, "clears": ["five_hour", "seven_day"],
                 "endsAt": \(millis(86_400)), "usableNow": true, "paused": false\(grant)}]}
    """)
}

@Suite struct ClaudeResetParsingTests {
    @Test func readsGrantsSoonestExpiryFirst() throws {
        let read = try status("""
        {"ok": true, "eligible": true, "atLimit": false, "exhausted": [], "nextGrantId": "late",
         "weeklyResetsAt": \(millis(3600)), "grants": [
          {"id": "late", "kind": "fable", "label": "Launch gift", "resetsLeft": 1, "resetsTotal": 1,
           "clears": ["seven_day_overage_included"], "endsAt": \(millis(9 * 86_400)), "usableNow": false,
           "paused": false, "unavailableReason": "not_limited", "useRequiresLimit": true},
          {"id": "soon", "kind": "weekly", "resetsLeft": 2, "clears": ["five_hour", "seven_day"],
           "endsAt": \(millis(86_400)), "usableNow": true, "paused": false},
          {"kind": "weekly", "resetsLeft": 1}]}
        """)
        #expect(read.grants.map(\.id) == ["soon", "late"])
        #expect(read.grants[1].kind == .fable)
        #expect(read.grants[1].isNext && !read.grants[0].isNext)
        #expect(read.grants[1].label == "Launch gift")
        #expect(read.grants[0].resetsTotal == nil)
        #expect(read.grants[1].useRequiresLimit == true && read.grants[0].useRequiresLimit == nil)
        #expect(read.weeklyResetsAt == now.addingTimeInterval(3600))
        #expect(read.readAt == now)
    }

    @Test func aRateLimitedReadSaysWhenToComeBack() throws {
        let failure = #expect(throws: ClaudeResets.Failure.self) {
            try status(#"{"ok": false, "error": "HTTP 429", "status": 429, "retryAt": \#(millis(120)), "sent": false}"#)
        }
        #expect(failure?.message == "Anthropic rate-limited the read")
        #expect(failure?.retryAt == now.addingTimeInterval(120))
        #expect(failure?.sent == false)
        #expect(failure?.rateLimited == true)
    }

    @Test func aReadingGoesStaleAfterFifteenMinutes() throws {
        let read = try listing()
        #expect(read.isFresh(at: now.addingTimeInterval(14 * 60)))
        #expect(!read.isFresh(at: now.addingTimeInterval(16 * 60)))
    }

    @Test func blocksWhatAnthropicWouldRefuse() throws {
        #expect(try listing().blocked(listing().grants[0], now: now) == nil)
        let ineligible = try listing(eligible: false)
        #expect(ineligible.blocked(ineligible.grants[0], now: now) == "Not eligible (plan tier)")
        var grant = try listing().grants[0]
        let read = try listing()
        grant.resetsLeft = 0
        #expect(read.blocked(grant, now: now) == "None left")
        grant = read.grants[0]
        grant.paused = true
        #expect(read.blocked(grant, now: now) == "Paused")
        grant = read.grants[0]
        grant.usableNow = false
        grant.unavailableReason = "not_limited"
        #expect(read.blocked(grant, now: now) == "Not usable now (not limited)")
        #expect(read.blocked(read.grants[0], now: now.addingTimeInterval(2 * 86_400)) == "Expired")
    }

    @Test func warnsWhenASpendMayBeWasted() throws {
        let atLimit = try listing()
        #expect(atLimit.warnings(atLimit.grants[0], now: now).isEmpty)

        let idle = try listing(atLimit: false, exhausted: "[]")
        let idleWarnings = idle.warnings(idle.grants[0], now: now)
        #expect(idleWarnings.count == 2)
        #expect(idleWarnings[0].contains("not at a usage limit"))
        #expect(idleWarnings[1] == "No weekly limit is exhausted.")

        // A reset that does not need a limit raises no "not at a limit" warning.
        let free = try listing(atLimit: false, exhausted: "[]", grant: #", "useRequiresLimit": false"#)
        #expect(free.warnings(free.grants[0], now: now) == ["No weekly limit is exhausted."])

        let fable = try listing(exhausted: #"["seven_day", "seven_day_overage_included"]"#, cooldown: "\(millis(600))")
        let warnings = fable.warnings(fable.grants[0], now: now)
        #expect(warnings.count == 2)
        #expect(warnings[0] == "It does not clear the Fable weekly limit, which is exhausted.")
        #expect(warnings[1].contains("cooldown"))
    }

    @Test func namesLimits() {
        #expect(ClaudeResets.limits(["seven_day"]) == "the weekly limit")
        #expect(ClaudeResets.limits(["five_hour", "seven_day"]) == "the 5-hour and weekly limits")
        #expect(ClaudeResets.limits(["five_hour", "seven_day", "seven_day_overage_included", "new_thing"])
            == "the 5-hour, weekly, Fable weekly and new thing limits")
        #expect(ClaudeResets.limits([]) == "no limit")
    }

    @Test func onlyAKnownAnswerIsAVerdict() throws {
        func claim(_ json: String) throws -> ClaudeResets.Verdict {
            try ClaudeResets.parseClaim(JSONValue.parse(Data(json.utf8)))
        }
        #expect(try claim(#"{"ok": true, "result": "reset", "cleared": ["seven_day"], "resetsLeft": 1}"#)
            == .spent(cleared: ["seven_day"], resetsLeft: 1, replay: false))
        #expect(try claim(#"{"ok": true, "result": "already_used", "cleared": []}"#)
            == .spent(cleared: [], resetsLeft: nil, replay: true))
        #expect(try claim(#"{"ok": true, "result": "not_limited"}"#) == .declined("not limited"))
        #expect(try claim(#"{"ok": true, "result": "cooldown", "reason": "recent_reset"}"#)
            == .declined("cooldown: recent reset"))

        // No verdict: the reset may be spent, unless the helper says nothing was sent.
        #expect(#expect(throws: ClaudeResets.Failure.self) { try claim(#"{"ok": true, "result": "granted"}"#) }?.sent == true)
        #expect(#expect(throws: ClaudeResets.Failure.self) { try claim(#"{"ok": true}"#) }?.sent == true)
        #expect(#expect(throws: ClaudeResets.Failure.self) { try ClaudeResets.parseClaim(nil) }?.sent == true)
        #expect(#expect(throws: ClaudeResets.Failure.self) { try claim(#"{"ok": false, "error": "HTTP 502"}"#) }?.sent == true)
        #expect(#expect(throws: ClaudeResets.Failure.self) {
            try claim(#"{"ok": false, "error": "account is disabled", "sent": false}"#)
        }?.sent == false)
    }

    @Test func nodePathIsConfigurable() throws {
        #expect(AppConfig().node == "/opt/homebrew/bin/node")
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"node": "/usr/local/bin/node"}"#.utf8))
        #expect(config.node == "/usr/local/bin/node")
    }
}

private actor Tries {
    private(set) var count = 0
    func next() -> Int { count += 1; return count - 1 }
    func reset() { count = 0 }
}

private let nodePath = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

/// The helper script, run by a real `node` against a stand-in TeamClaude install whose modules
/// record how they were called. Nothing here reaches Anthropic.
@Suite(.enabled(if: nodePath != nil, "needs node")) struct ClaudeResetHelperTests {
    static let token = "sk-ant-oat-TEST-TOKEN"

    struct Install {
        var dir: String
        var log: URL

        func environment(fetch: String = "null", claim: String = "null") -> [String: String] {
            ["PATH": "/usr/bin:/bin", "CALL_LOG": log.path, "FETCH_REPLY": fetch, "CLAIM_REPLY": claim]
        }

        /// The calls the stand-in modules received, one JSON object each.
        func calls() throws -> [JSONValue] {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
            return try text.split(separator: "\n").map { try JSONValue.parse(Data($0.utf8)) }
        }
    }

    /// A stand-in `node_modules/@karpeleslab/teamclaude` with the given accounts.
    func install(accounts: String, resets: String? = nil) throws -> Install {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-bar-\(UUID().uuidString)")
        let package = root.appendingPathComponent("node_modules/@karpeleslab/teamclaude")
        let src = package.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let files: [(URL, String)] = [
            (package.appendingPathComponent("package.json"), #"{"type": "module"}"#),
            (package.appendingPathComponent("config.json"), #"{"accounts": \#(accounts)}"#),
            (src.appendingPathComponent("config.js"), """
            import { readFileSync } from 'node:fs';
            export async function loadConfig() {
              return JSON.parse(readFileSync(new URL('../config.json', import.meta.url), 'utf-8'));
            }
            """),
            (src.appendingPathComponent("resolve-accounts.js"), """
            export async function resolveAccounts(config) {
              console.log('{"imported": "noise on stdout"}');
              return config.accounts.filter(a => a.accessToken);
            }
            """),
            (src.appendingPathComponent("provider.js"), """
            export const DEFAULT_PROVIDER = 'anthropic';
            export const providerOf = account => account.provider || DEFAULT_PROVIDER;
            """),
            (src.appendingPathComponent("account-manager.js"),
             "export const accountRouting = (account, listener) => account.routing === 'broken' ? null : { via: account.routing, listener };"),
            (src.appendingPathComponent("upstream-proxy.js"), "export const localListener = () => 'listener';"),
            (src.appendingPathComponent("claude-resets.js"), resets ?? """
            import { appendFileSync } from 'node:fs';
            const record = entry => appendFileSync(process.env.CALL_LOG, JSON.stringify(entry) + '\\n');
            // A reply may name its retry time as a delay from now.
            const reply = raw => {
              if (raw === 'exit') process.exit(3);
              const answer = JSON.parse(raw);
              return answer?.retryIn != null ? { ...answer, retryAt: Date.now() + answer.retryIn } : answer;
            };
            export async function fetchClaudeResetStatus(account) {
              record({ fn: 'fetch', credential: account.credential, org: account.orgUuid, routing: account.routing });
              return reply(process.env.FETCH_REPLY);
            }
            export async function claimClaudeReset(account, request) {
              record({ fn: 'claim', credential: account.credential, org: account.orgUuid, ...request });
              return reply(process.env.CLAIM_REPLY);
            }
            export const claudeGrantKind = grant => grant.type === 'session' ? 'session'
              : grant.clears.includes('seven_day') ? 'weekly' : 'fable';
            """),
        ]
        for (url, text) in files { try text.write(to: url, atomically: true, encoding: .utf8) }
        return Install(dir: root.path, log: root.appendingPathComponent("calls.log"))
    }

    static let live = Int(Date().timeIntervalSince1970 * 1000) + 3_600_000
    static let accounts = """
    [{"name": "a@example.com", "type": "oauth", "accessToken": "\(token)", "orgUuid": "org-a", "expiresAt": \(live)},
     {"name": "a@example.com", "type": "oauth", "provider": "codex", "accessToken": "codex-token"},
     {"name": "b@example.com", "type": "oauth", "accessToken": "other-token", "orgUuid": "org-b", "expiresAt": \(live)}]
    """
    static let reading = """
    {"reset": {"eligible": true, "ineligibleReason": null, "atLimit": true, "exhausted": ["seven_day"],
     "cooldownUntil": null, "weeklyResetsAt": null, "nextGrantId": "grant_1", "grants": [
      {"id": "grant_1", "label": "Gift", "resetsLeft": 2, "resetsTotal": 3, "clears": ["five_hour", "seven_day"],
       "endsAt": \(live), "usableNow": true, "paused": false, "type": "weekly", "useRequiresLimit": true,
       "unavailableReason": null}]}, "usage": {"secret": "not for the app"}}
    """

    func failure(_ body: () async throws -> Void) async -> ClaudeResets.Failure? {
        do {
            try await body()
            return nil
        } catch {
            return error as? ClaudeResets.Failure
        }
    }

    @Test func listsTheNamedClaudeAccountWithoutLeakingItsToken() async throws {
        let stub = try install(accounts: Self.accounts)
        let node = try #require(nodePath)
        let result = try await Shell.run(node, ClaudeResets.arguments(installDir: stub.dir, ["list", "a@example.com"]),
                                         environment: stub.environment(fetch: Self.reading), timeout: 20)
        // The token stays in the child: not in its output, and not in its arguments.
        #expect(!result.output.contains(Self.token) && !result.errorOutput.contains(Self.token))
        #expect(!result.output.contains("not for the app"))
        #expect(!ClaudeResets.arguments(installDir: stub.dir, ["list", "a@example.com"]).joined().contains(Self.token))

        let read = try await ClaudeResets.list(node: node, installDir: stub.dir, account: "a@example.com",
                                               environment: stub.environment(fetch: Self.reading))
        #expect(read.eligible && read.atLimit && read.exhausted == ["seven_day"])
        #expect(read.grants.count == 1)
        #expect(read.grants[0].id == "grant_1" && read.grants[0].kind == .weekly && read.grants[0].isNext)
        #expect(read.grants[0].resetsLeft == 2 && read.grants[0].resetsTotal == 3)

        // The Claude account of that name was used, not the Codex one that shares it.
        let call = try #require(try stub.calls().last)
        #expect(call["fn"]?.string == "fetch")
        #expect(call["credential"]?.string == Self.token)
        #expect(call["org"]?.string == "org-a")
        #expect(call["routing"]?.isNull == true)
    }

    @Test func reportsARateLimitedRead() async throws {
        let stub = try install(accounts: Self.accounts)
        let retry = Self.live
        let failed = await failure {
            _ = try await ClaudeResets.list(
                node: try #require(nodePath), installDir: stub.dir, account: "a@example.com",
                environment: stub.environment(fetch: #"{"error": "HTTP 429", "status": 429, "retryAt": \#(retry)}"#))
        }
        #expect(failed?.message == "Anthropic rate-limited the read")
        #expect(failed?.retryAt == Date(timeIntervalSince1970: Double(retry) / 1000))
    }

    @Test(arguments: [
        ("nobody@example.com", "no Claude account has this name"),
        ("expired@example.com", "the stored token has expired"),
        ("off@example.com", "account is disabled"),
        ("long@example.com", "long-lived"),
        ("noorg@example.com", "no token or organization id"),
        ("twin@example.com", "more than one"),
        ("backend@example.com", "no Claude account has this name"),
        ("broken@example.com", "routing"),
    ])
    func refusesAnAccountItShouldNotTouch(account: String, reason: String) async throws {
        let stub = try install(accounts: """
        [{"name": "expired@example.com", "type": "oauth", "accessToken": "t", "orgUuid": "o", "expiresAt": 1000},
         {"name": "off@example.com", "type": "oauth", "accessToken": "t", "orgUuid": "o", "disabled": true},
         {"name": "long@example.com", "type": "oauth", "accessToken": "t", "orgUuid": "o", "longLived": true},
         {"name": "noorg@example.com", "type": "oauth", "accessToken": "t"},
         {"name": "twin@example.com", "type": "oauth", "accessToken": "t", "orgUuid": "o"},
         {"name": "twin@example.com", "type": "oauth", "accessToken": "t", "orgUuid": "o"},
         {"name": "backend@example.com", "type": "oauth", "accessToken": "t", "orgUuid": "o", "upstream": "https://x"},
         {"name": "broken@example.com", "type": "oauth", "accessToken": "t", "orgUuid": "o", "routing": "broken"}]
        """)
        let node = try #require(nodePath)
        let read = await failure {
            _ = try await ClaudeResets.list(node: node, installDir: stub.dir, account: account,
                                            environment: stub.environment(fetch: Self.reading))
        }
        #expect(read?.message.contains(reason) == true, "\(read?.message ?? "no failure")")
        let claim = await failure {
            _ = try await ClaudeResets.claim(node: node, installDir: stub.dir, account: account, grantID: "grant_1",
                                             requestID: "req-1", environment: stub.environment(claim: #"{"result": "reset"}"#))
        }
        #expect(claim?.message.contains(reason) == true)
        #expect(claim?.sent == false)
        // Neither the read nor the spend got as far as Anthropic's functions.
        #expect(try stub.calls().isEmpty)
    }

    @Test func anAccountWithItsOwnRouteKeepsIt() async throws {
        let stub = try install(accounts: """
        [{"name": "a@example.com", "type": "oauth", "accessToken": "t", "orgUuid": "o", "routing": "socks://proxy"}]
        """)
        _ = try await ClaudeResets.list(node: try #require(nodePath), installDir: stub.dir, account: "a@example.com",
                                        environment: stub.environment(fetch: Self.reading))
        let call = try #require(try stub.calls().last)
        #expect(call["routing"]?["via"]?.string == "socks://proxy")
        #expect(call["routing"]?["listener"]?.string == "listener")
    }

    @Test func spendsTheNamedResetUnderTheGivenRequestID() async throws {
        let stub = try install(accounts: Self.accounts)
        let verdict = try await ClaudeResets.claim(
            node: try #require(nodePath), installDir: stub.dir, account: "a@example.com", grantID: "grant_1",
            requestID: "5F0C-req", environment: stub.environment(
                claim: #"{"result": "reset", "reason": null, "resetsLeft": 1, "cleared": ["five_hour", "seven_day"]}"#))
        #expect(verdict == .spent(cleared: ["five_hour", "seven_day"], resetsLeft: 1, replay: false))
        let calls = try stub.calls()
        #expect(calls.count == 1)  // a spend does not read first
        #expect(calls[0]["fn"]?.string == "claim")
        #expect(calls[0]["grantId"]?.string == "grant_1")
        #expect(calls[0]["requestId"]?.string == "5F0C-req")
        #expect(calls[0]["credential"]?.string == Self.token)
        #expect(calls[0]["org"]?.string == "org-a")
    }

    @Test func aDeclineSpendsNothing() async throws {
        let stub = try install(accounts: Self.accounts)
        let verdict = try await ClaudeResets.claim(
            node: try #require(nodePath), installDir: stub.dir, account: "a@example.com", grantID: "grant_1",
            requestID: "req-2", environment: stub.environment(claim: #"{"result": "not_limited", "reason": null}"#))
        #expect(verdict == .declined("not limited"))
    }

    @Test(arguments: [
        (#"{"error": "HTTP 502", "status": 502}"#, true),  // the request left; Anthropic gave no verdict
        (#"{"error": "malformed grant id"}"#, false),      // refused before anything was sent
        ("exit", true),                                    // the helper died mid-request
        (#"{"result": "something_new"}"#, true),           // an answer this app does not know
    ])
    func aSpendWithoutAVerdictSaysWhetherItMayHaveGoneOut(reply: String, sent: Bool) async throws {
        let stub = try install(accounts: Self.accounts)
        let failed = await failure {
            _ = try await ClaudeResets.claim(
                node: try #require(nodePath), installDir: stub.dir, account: "a@example.com", grantID: "grant_1",
                requestID: "req-3", environment: stub.environment(claim: reply))
        }
        #expect(failed?.sent == sent, "\(failed?.message ?? "no failure")")
    }

    @Test(arguments: [("Grant 1", "req-1"), ("grant_1", "bad id!"), ("", "req-1")])
    func malformedIdsNeverReachAnthropic(grant: String, request: String) async throws {
        let stub = try install(accounts: Self.accounts)
        let failed = await failure {
            _ = try await ClaudeResets.claim(
                node: try #require(nodePath), installDir: stub.dir, account: "a@example.com", grantID: grant,
                requestID: request, environment: stub.environment(claim: #"{"result": "reset"}"#))
        }
        #expect(failed?.sent == false)
        #expect(try stub.calls().isEmpty)
    }

    /// The whole path: the script reports HTTP 429, the queue holds the account until the time
    /// Anthropic named, then sends the same call again.
    @Test func theQueueWaitsOutARateLimitedReadAndSpend() async throws {
        let stub = try install(accounts: Self.accounts)
        let node = try #require(nodePath)
        var policy = APIQueue.Policy()
        policy.spacing = 0
        policy.margin = 0.05
        policy.backoff = 0.3
        let queue = APIQueue(policy: policy)
        let tries = Tries()

        let limited = #"{"error": "HTTP 429", "status": 429, "retryIn": 400}"#
        let started = Date()
        let read = try await queue.run(lane: "read a@example.com", label: "read") {
            let reply = await tries.next() == 0 ? limited : Self.reading
            return try await ClaudeResets.list(node: node, installDir: stub.dir, account: "a@example.com",
                                               environment: stub.environment(fetch: reply))
        }
        #expect(read.grants.count == 1)
        #expect(await tries.count == 2)
        #expect(Date().timeIntervalSince(started) >= 0.4)

        // A spend that is rate-limited names no retry time; it goes again under the same request id.
        await tries.reset()
        let verdict = try await queue.run(lane: "spend a@example.com", label: "spend") {
            let reply = await tries.next() == 0 ? #"{"error": "HTTP 429", "status": 429}"# : #"{"result": "reset", "cleared": ["seven_day"]}"#
            return try await ClaudeResets.claim(node: node, installDir: stub.dir, account: "a@example.com",
                                                grantID: "grant_1", requestID: "req-same",
                                                environment: stub.environment(claim: reply))
        }
        #expect(verdict == .spent(cleared: ["seven_day"], resetsLeft: nil, replay: false))
        let claims = try stub.calls().filter { $0["fn"]?.string == "claim" }
        #expect(claims.count == 2)
        #expect(claims.allSatisfy { $0["requestId"]?.string == "req-same" && $0["grantId"]?.string == "grant_1" })
        #expect(await queue.snapshot().entries.isEmpty)
    }

    @Test func aRateLimitedSpendIsMarkedForTheQueue() async throws {
        let stub = try install(accounts: Self.accounts)
        let failed = await failure {
            _ = try await ClaudeResets.claim(
                node: try #require(nodePath), installDir: stub.dir, account: "a@example.com", grantID: "grant_1",
                requestID: "req-4", environment: stub.environment(claim: #"{"error": "HTTP 429", "status": 429}"#))
        }
        #expect(failed?.rateLimited == true)
        #expect(failed?.sent == true)  // if the wait is abandoned, this is still no verdict
        #expect(failed?.message == "Anthropic rate-limited the request")
        let other = await failure {
            _ = try await ClaudeResets.claim(
                node: try #require(nodePath), installDir: stub.dir, account: "a@example.com", grantID: "grant_1",
                requestID: "req-5", environment: stub.environment(claim: #"{"error": "HTTP 502", "status": 502}"#))
        }
        #expect(other?.rateLimited == false)
    }

    @Test func failsClearlyWhenTeamClaudeChanged() async throws {
        let node = try #require(nodePath)
        let renamed = try install(accounts: Self.accounts, resets: """
        export async function fetchClaudeResetStatus() { return {}; }
        export async function claimClaudeReset() { return {}; }
        """)
        let missingFunction = await failure {
            _ = try await ClaudeResets.claim(node: node, installDir: renamed.dir, account: "a@example.com",
                                             grantID: "grant_1", requestID: "req-1", environment: renamed.environment())
        }
        #expect(missingFunction?.message == "this TeamClaude version has no claudeGrantKind")
        #expect(missingFunction?.sent == false)

        let absent = await failure {
            _ = try await ClaudeResets.list(node: node, installDir: "/nonexistent/teamclaude", account: "a@example.com",
                                            environment: ["PATH": "/usr/bin:/bin"])
        }
        #expect(absent?.message.contains("Cannot find module") == true, "\(absent?.message ?? "no failure")")
    }
}
