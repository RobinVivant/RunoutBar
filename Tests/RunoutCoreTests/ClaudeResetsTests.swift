import Foundation
import Network
import Testing
@testable import RunoutCore

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

    @Test func parsesControlRouteResetDetailsWithServerBlocksAndWarnings() throws {
        let json = try JSONValue.parse(Data("""
        {
          "ok": true,
          "account": "a@example.com",
          "read": false,
          "readableAt": \(millis(120)),
          "details": {
            "provider": "claude",
            "error": "retry in 60s",
            "seenAt": \(millis(-300)),
            "stale": true,
            "retryAt": \(millis(60)),
            "ineligibleReason": null,
            "atLimit": false,
            "exhausted": [],
            "cooldownUntil": null,
            "weeklyResetsAt": \(millis(7200)),
            "fleetHoldUntil": \(millis(1800)),
            "grants": [
              {"id": "g1", "kind": "weekly", "label": "Gift", "resetsLeft": 2, "resetsTotal": 3,
               "clears": ["five_hour", "seven_day"], "endsAt": \(millis(86_400)), "next": true,
               "blocked": null, "warnings": ["not at a usage limit"]},
              {"id": "g2", "kind": "fable", "label": null, "resetsLeft": 1, "resetsTotal": 1,
               "clears": ["seven_day_overage_included"], "endsAt": \(millis(172_800)), "next": false,
               "blocked": "reset is paused", "warnings": []}
            ]
          }
        }
        """.utf8))
        let parsed = try ClaudeResets.parseStatus(json, now: now)
        #expect(parsed.stale)
        #expect(parsed.error == "retry in 60s")
        #expect(parsed.readAt == now.addingTimeInterval(-300))
        #expect(parsed.readableAt == now.addingTimeInterval(120))
        #expect(parsed.fleetHoldUntil == now.addingTimeInterval(1800))
        #expect(parsed.grants.count == 2)
        #expect(parsed.grants[0].isNext)
        #expect(parsed.blocked(parsed.grants[0], now: now) == nil)
        #expect(parsed.warnings(parsed.grants[0], now: now) == ["not at a usage limit"])
        #expect(parsed.blocked(parsed.grants[1], now: now) == "reset is paused")
        #expect(parsed.warnings(parsed.grants[1], now: now).isEmpty)
        #expect(parsed.blocked(parsed.grants[0], now: now.addingTimeInterval(2 * 86_400)) == "Expired")
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

        #expect(#expect(throws: ClaudeResets.Failure.self) { try claim(#"{"ok": true, "result": "granted"}"#) }?.sent == true)
        #expect(#expect(throws: ClaudeResets.Failure.self) { try claim(#"{"ok": true}"#) }?.sent == true)
        #expect(#expect(throws: ClaudeResets.Failure.self) { try ClaudeResets.parseClaim(nil) }?.sent == true)
        #expect(#expect(throws: ClaudeResets.Failure.self) { try claim(#"{"ok": false, "error": "HTTP 502"}"#) }?.sent == true)
        #expect(#expect(throws: ClaudeResets.Failure.self) {
            try claim(#"{"ok": false, "error": "account is disabled", "sent": false}"#)
        }?.sent == false)
    }

    @Test func parsesHTTPControlRouteRedeemReplies() throws {
        func redeem(_ status: Int, _ body: String) throws -> ClaudeResets.Verdict {
            try ClaudeResets.parseRedeem(status: status, json: JSONValue.parse(Data(body.utf8)))
        }
        #expect(try redeem(200, #"{"ok":true,"redeemed":true,"result":"reset","resetsLeft":1,"cleared":["seven_day"]}"#)
            == .spent(cleared: ["seven_day"], resetsLeft: 1, replay: false))
        #expect(try redeem(200, #"{"ok":true,"redeemed":true,"result":"already_used","cleared":[]}"#)
            == .spent(cleared: [], resetsLeft: nil, replay: true))
        #expect(try redeem(409, #"{"ok":false,"redeemed":false,"uncertain":false,"error":"Manual reset on \"a@example.com\": a reset was spent within the last hour"}"#)
            == .declined("a reset was spent within the last hour"))

        let uncertain = #expect(throws: ClaudeResets.Failure.self) {
            try redeem(502, #"{"ok":false,"redeemed":false,"uncertain":true,"error":"Manual reset on \"a@example.com\": upstream 502"}"#)
        }
        #expect(uncertain?.sent == true)

        let unauth = #expect(throws: ClaudeResets.Failure.self) {
            try redeem(401, #"{"type":"error","error":{"type":"authentication_error","message":"Invalid proxy API key"}}"#)
        }
        #expect(unauth?.sent == false)
        #expect(unauth?.message.contains("proxyApiKey") == true)

        let forbidden = #expect(throws: ClaudeResets.Failure.self) {
            try redeem(403, #"{"ok":false,"error":"a client key cannot spend resets"}"#)
        }
        #expect(forbidden?.sent == false)
    }

    @Test func controlURLOverridesPortForDefaultDashboardAndFollowsTeamRouterPrefix() {
        #expect(ClaudeResets.controlBaseURL(dashboard: "http://127.0.0.1:3456/teamclaude/dashboard", port: 4567)?.absoluteString
            == "http://127.0.0.1:4567")
        #expect(ClaudeResets.controlBaseURL(dashboard: "https://proxy.example.com:8443/teamrouter/dashboard", port: 4567)?.absoluteString
            == "https://proxy.example.com:8443")
        #expect(ClaudeResets.routePrefix(dashboard: "http://127.0.0.1:3456/teamrouter/dashboard") == "/teamrouter")
        #expect(ClaudeResets.routePrefix(dashboard: "http://127.0.0.1:3456/teamclaude/dashboard") == "/teamclaude")
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

/// Tests `ClaudeResets` over HTTP against a local `NWListener` stub server.
@Suite struct ClaudeResetRouteTests {
    struct RecordedRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: JSONValue?
    }

    final class StubServer: @unchecked Sendable {
        private final class State: @unchecked Sendable {
            let lock = NSLock()
            let handler: @Sendable (RecordedRequest) -> (Int, String)
            private var recorded: [RecordedRequest] = []

            init(_ handler: @escaping @Sendable (RecordedRequest) -> (Int, String)) {
                self.handler = handler
            }

            func record(_ req: RecordedRequest) {
                lock.lock(); recorded.append(req); lock.unlock()
            }

            var requests: [RecordedRequest] {
                lock.lock(); defer { lock.unlock() }; return recorded
            }
        }

        let listener: NWListener
        let port: UInt16
        private let state: State

        var requests: [RecordedRequest] { state.requests }

        init(handler: @escaping @Sendable (RecordedRequest) -> (Int, String)) async throws {
            let listener = try NWListener(using: .tcp, on: .any)
            let state = State(handler)
            self.listener = listener
            self.state = state
            let ReadyStream = AsyncStream<Bool> { stateCont in
                listener.stateUpdateHandler = { state in
                    if case .ready = state { stateCont.yield(true) }
                    if case .failed = state { stateCont.yield(false) }
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                Self.readHTTPRequest(connection: connection, buffer: Data()) { req in
                    guard let req else { connection.cancel(); return }
                    state.record(req)
                    let (status, body) = state.handler(req)
                    let reply = "HTTP/1.1 \(status) Status\r\nContent-Type: application/json\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: .global())
            var it = ReadyStream.makeAsyncIterator()
            #expect(await it.next() == true)
            self.port = try #require(listener.port?.rawValue)
        }

        func stop() { listener.cancel() }

        private static func readHTTPRequest(connection: NWConnection, buffer: Data,
                                            done: @escaping (RecordedRequest?) -> Void) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, _ in
                var data = buffer
                if let chunk { data.append(chunk) }
                if let split = data.range(of: Data("\r\n\r\n".utf8)) {
                    let headerText = String(decoding: data[..<split.lowerBound], as: UTF8.self)
                    let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
                    let first = lines.first?.split(separator: " ") ?? []
                    let method = first.count > 0 ? String(first[0]) : ""
                    let path = first.count > 1 ? String(first[1]) : ""
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        if let colon = line.firstIndex(of: ":") {
                            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                            headers[key] = value
                        }
                    }
                    let expectedLength = headers["content-length"].flatMap(Int.init) ?? 0
                    let bodyData = Data(data[split.upperBound...])
                    if bodyData.count >= expectedLength || isComplete {
                        let slice = Data(bodyData.prefix(expectedLength))
                        let parsed = slice.isEmpty ? nil : (try? JSONValue.parse(slice))
                        done(RecordedRequest(method: method, path: path, headers: headers, body: parsed))
                        return
                    }
                }
                if isComplete { done(nil); return }
                readHTTPRequest(connection: connection, buffer: data, done: done)
            }
        }
    }

    static let sampleGrant = """
    {"id":"grant_1","kind":"weekly","label":"Gift","resetsLeft":2,"resetsTotal":3,
     "clears":["five_hour","seven_day"],"endsAt":\(millis(86_400)),"next":true,
     "blocked":null,"warnings":["not at a usage limit"]}
    """

    static let readSuccess = """
    {"ok":true,"account":"a@example.com","read":true,"readableAt":\(millis(120)),
     "details":{"provider":"claude","error":null,"seenAt":\(millis(-10)),"stale":false,"retryAt":null,
      "ineligibleReason":null,"atLimit":true,"exhausted":["seven_day"],"cooldownUntil":null,
      "weeklyResetsAt":\(millis(7200)),"fleetHoldUntil":null,"grants":[\(sampleGrant)]}}
    """

    @Test func fetchesCachedResetsReadsAndRedeemsViaControlRoutes() async throws {
        let server = try await StubServer { req in
            if req.method == "GET", req.path == "/teamclaude/resets" {
                return (200, """
                {"ok":true,"accounts":[
                  {"account":"a@example.com","provider":"claude","readableAt":\(millis(90)),
                   "details":{"provider":"claude","error":null,"seenAt":\(millis(-30)),"stale":false,"retryAt":null,
                    "ineligibleReason":null,"atLimit":true,"exhausted":["seven_day"],"cooldownUntil":null,
                    "weeklyResetsAt":null,"fleetHoldUntil":null,"grants":[\(Self.sampleGrant)]}},
                  {"account":"empty@example.com","provider":"claude","readableAt":null,"details":null},
                  {"account":"openai","provider":"codex","readableAt":null,"details":{"provider":"codex","grants":[]}}
                ]}
                """)
            }
            if req.method == "POST", req.path == "/teamclaude/resets/read" {
                return (200, Self.readSuccess)
            }
            if req.method == "POST", req.path == "/teamclaude/resets/redeem" {
                return (200, #"{"ok":true,"account":"a@example.com","redeemed":true,"result":"reset","resetsLeft":1,"cleared":["five_hour","seven_day"]}"#)
            }
            return (404, #"{"ok":false,"error":"not found"}"#)
        }
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        let dashboard = "http://127.0.0.1:\(server.port)/teamclaude/dashboard"

        let cached = try await ClaudeResets.fetchCached(dashboard: dashboard, apiKey: "secret-key",
                                                        session: session, now: now)
        #expect(cached.keys.sorted() == ["a@example.com"])
        #expect(cached["a@example.com"]?.grants.map(\.id) == ["grant_1"])

        let read = try await ClaudeResets.list(dashboard: dashboard, apiKey: "secret-key",
                                               account: "a@example.com", session: session, now: now)
        #expect(read.grants.count == 1)
        #expect(read.readableAt == now.addingTimeInterval(120))

        let verdict = try await ClaudeResets.claim(dashboard: dashboard, apiKey: "secret-key",
                                                   account: "a@example.com", grantID: "grant_1", session: session)
        #expect(verdict == .spent(cleared: ["five_hour", "seven_day"], resetsLeft: 1, replay: false))

        let reqs = server.requests
        #expect(reqs.count == 3)
        #expect(reqs.allSatisfy { $0.headers["x-api-key"] == "secret-key" })
        #expect(reqs[1].body?["account"]?.string == "a@example.com")
        #expect(reqs[2].body?["account"]?.string == "a@example.com")
        #expect(reqs[2].body?["grantId"]?.string == "grant_1")
    }

    @Test func malformedGrantIdNeverReachesProxy() async throws {
        let server = try await StubServer { _ in (200, #"{"ok":true,"redeemed":true}"#) }
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        for bad in ["Grant 1", "bad/id", ""] {
            var caught: ClaudeResets.Failure?
            do {
                _ = try await ClaudeResets.claim(
                    dashboard: "http://127.0.0.1:\(server.port)/teamclaude/dashboard",
                    account: "a@example.com", grantID: bad, session: session)
            } catch let failure as ClaudeResets.Failure {
                caught = failure
            }
            #expect(caught?.sent == false)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func routeSupportsTeamRouterPrefixAndQueueRetriesAfter429() async throws {
        let counter = AttemptCounter()
        let server = try await StubServer { req in
            if req.method == "POST", req.path == "/teamrouter/resets/read" {
                let n = counter.next()
                if n == 1 {
                    let retryAt = Date().addingTimeInterval(0.4).timeIntervalSince1970 * 1000
                    return (200, """
                    {"ok":true,"account":"a@example.com","read":false,"readableAt":\(retryAt),
                     "details":{"provider":"claude","error":"HTTP 429","seenAt":null,"stale":false,
                                "retryAt":\(retryAt),"grants":[]}}
                    """)
                }
                return (200, Self.readSuccess)
            }
            if req.method == "POST", req.path == "/teamrouter/resets/redeem" {
                return (502, #"{"ok":false,"redeemed":false,"uncertain":true,"error":"HTTP 502"}"#)
            }
            return (404, "{}")
        }
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        let dashboard = "http://127.0.0.1:\(server.port)/teamrouter/dashboard"

        var policy = APIQueue.Policy()
        policy.spacing = 0
        policy.margin = 0.05
        policy.backoff = 0.3
        let queue = APIQueue(policy: policy)

        let started = Date()
        let read = try await queue.run(lane: "read a@example.com", label: "read") {
            try await ClaudeResets.list(dashboard: dashboard, account: "a@example.com", session: session, now: now)
        }
        #expect(read.grants.count == 1)
        #expect(Date().timeIntervalSince(started) >= 0.35)
        #expect(await queue.snapshot().entries.isEmpty)

        var redeemError: ClaudeResets.Failure?
        do {
            _ = try await ClaudeResets.claim(dashboard: dashboard, account: "a@example.com",
                                               grantID: "grant_1", session: session)
        } catch let failure as ClaudeResets.Failure {
            redeemError = failure
        }
        #expect(redeemError?.sent == true)
        #expect(redeemError?.message == "HTTP 502")
    }
}
