import Foundation
import Testing
@testable import RunoutCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func config() -> AppConfig {
    var config = AppConfig()
    config.accounts = [
        "personal@example.com": AccountStyle(letter: "P", label: "Personal", noFiveHourLimit: true),
        "work@example.com": AccountStyle(letter: "W", label: "Work"),
        "icloud@example.com": AccountStyle(letter: "I", label: "iCloud", noFiveHourLimit: true),
    ]
    return config
}

private func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

@Suite struct TeamClaudeStatusTests {
    @Test func parsesLiveStatusShape() throws {
        let (accounts, proxy) = try TeamClaudeStatus.parse(try fixture("teamclaude-status"), config: config())
        // Only enabled Anthropic accounts; the Codex row comes from the app server.
        #expect(accounts.map(\.id) == ["personal@example.com", "work@example.com", "icloud@example.com"])
        #expect(proxy.up)
        #expect(proxy.version == "1.1.26")
        #expect(proxy.threshold == 98)
        #expect(proxy.currentAccount == "personal@example.com")
        #expect(proxy.probeInterval == 60)

        let personal = accounts[0]
        #expect(personal.routing)
        #expect(personal.window("5h") == nil)
        #expect(personal.sessionNote == .noLimit)
        #expect(personal.window("7d")?.used == 52)
        #expect(personal.window("7d.fable")?.title == "Fable weekly")
        let forecast = try #require(personal.window("7d")?.forecast)
        #expect(abs((forecast.ratePerHour ?? 0) - 3.381) < 0.01)
        #expect(forecast.reachesThresholdAt != nil)
        #expect(personal.recentModels.first == "claude-opus-5-5")
        #expect(personal.spend?.contains("out of credits") == true)

        // Banked resets: counts only, with the Fable-only share and the earliest expiry.
        let resets = try #require(personal.resets)
        #expect(resets.available == 4)
        #expect(resets.usableNow == 4)
        #expect(resets.fableOnly == 3)
        #expect(resets.nextExpiry == Date(timeIntervalSince1970: 1_796_940_000))
        #expect(resets.grants == nil)
        #expect(accounts[1].resets?.fableOnly == 0)

        // Work still reports a 5-hour window alongside the weekly one.
        #expect(accounts[1].window("5h")?.used == 0)
        // iCloud's last 5-hour reading is days older than its weekly reading.
        #expect(accounts[2].window("5h") == nil)
        #expect(accounts[2].sessionNote == .noLimit)
    }

    @Test func staleFiveHourWithoutConfigIsReportedAsNotSeen() throws {
        let (accounts, _) = try TeamClaudeStatus.parse(try fixture("teamclaude-status"), config: AppConfig())
        guard case .notReportedSince = accounts[2].sessionNote else {
            Issue.record("expected notReportedSince, got \(String(describing: accounts[2].sessionNote))")
            return
        }
        // With no configuration and no reading at all, the window stays visible as unknown.
        #expect(accounts[0].window("5h") != nil)
        #expect(accounts[0].window("5h")?.used == nil)
    }

    @Test func explicitSessionWindowStatedWins() {
        let now = Date()
        let quota: JSONValue = .object([
            "sessionWindowStated": .bool(true),
            "unified5h": .number(0.4),
            "unified5hSeenAt": .number(ms(now.addingTimeInterval(-86_400))),
            "unified7dSeenAt": .number(ms(now)),
        ])
        #expect(TeamClaudeStatus.sessionWindow(quota: quota, configuredNoLimit: true) == .present)
    }

    @Test func freshFiveHourReadingOverridesConfiguredExemption() {
        let now = Date()
        let quota: JSONValue = .object([
            "unified5h": .number(0.2),
            "unified5hSeenAt": .number(ms(now)),
            "unified7dSeenAt": .number(ms(now)),
        ])
        #expect(TeamClaudeStatus.sessionWindow(quota: quota, configuredNoLimit: true) == .present)
    }

    @Test func failedProbeIsNotAFreshObservation() {
        let seen = Date(timeIntervalSince1970: 1_000_000)
        let quota: JSONValue = .object(["unified7d": .number(0.5), "unified7dSeenAt": .number(ms(seen))])
        let probe: JSONValue = .object(["status": .string("error"), "lastProbedAt": .string("2030-01-01T00:00:00Z")])
        #expect(TeamClaudeStatus.quotaFetchedAt(quota: quota, probe: probe) == seen)
    }

    @Test func readsServerPortAndIgnoresUnknownFields() throws {
        let data = Data("""
        {"server": {"version": "2.0.0", "port": 4567, "futureFlag": true},
         "probe": {"enabled": true, "intervalSeconds": 120, "accounts": []},
         "accounts": [],
         "newTopLevelField": {"nested": [1, 2, 3]}}
        """.utf8)
        let (accounts, proxy) = try TeamClaudeStatus.parse(data, config: AppConfig())
        #expect(accounts.isEmpty)
        #expect(proxy.up)
        #expect(proxy.version == "2.0.0")
        #expect(proxy.port == 4567)
    }
}

@Suite struct CodexTests {
    @Test func parsesBucketsAndCredits() throws {
        let now = Date(timeIntervalSince1970: 1_794_482_000)
        let snapshot = try Codex.parse(try fixture("codex-ratelimits"), now: now)
        #expect(snapshot.id == "openai")
        #expect(snapshot.windows.map(\.id) == ["5h", "7d"])
        #expect(snapshot.window("7d")?.used == 36)
        #expect(snapshot.window("7d")?.duration == TimeInterval(7 * 86_400))
        #expect(snapshot.plan == "Business Prolite")
        #expect(!snapshot.blocked)
        #expect(snapshot.fetchedAt == now)
    }

    @Test func listsAvailableResetsSoonestExpiryFirst() throws {
        let now = Date(timeIntervalSince1970: 1_794_482_000)
        let resets = try #require(try Codex.parse(try fixture("codex-ratelimits"), now: now).resets)
        #expect(resets.available == 2)
        // The redeemed credit is dropped; the one that expires first is the one a redeem names.
        #expect(resets.grants?.map(\.id) == ["RateLimitResetCredit_sooner", "RateLimitResetCredit_later"])
        #expect(resets.nextGrant?.id == "RateLimitResetCredit_sooner")
        #expect(resets.nextExpiry == Date(timeIntervalSince1970: 1_796_068_659))
        #expect(resets.nextGrant?.title == "Full reset")
    }

    @Test func resetCountsWithoutDetailRows() throws {
        let now = Date(timeIntervalSince1970: 1_794_482_000)
        func credits(_ json: String) throws -> ResetCredits? {
            Codex.resetCredits(try JSONValue.parse(Data(json.utf8)), now: now)
        }
        // Only a count: the server picks the credit, so no id is named.
        let countOnly = try #require(try credits(#"{"availableCount": 3, "credits": null}"#))
        #expect(countOnly.available == 3)
        #expect(countOnly.grants == nil)
        #expect(countOnly.nextGrant == nil)
        // An expired row is not offered.
        let expired = #"{"availableCount": 0, "credits": [{"id": "a", "status": "available", "grantedAt": 1, "expiresAt": 2}]}"#
        #expect(try credits(expired) == nil)
        #expect(try credits(#"{"availableCount": 0, "credits": []}"#) == nil)
        #expect(Codex.resetCredits(nil, now: now) == nil)
    }

    @Test func redeemRequestAndOutcomes() throws {
        let named = Codex.consumeParams(creditID: "c1", idempotencyKey: "k1")
        #expect(named["creditId"] as? String == "c1")
        #expect(named["idempotencyKey"] as? String == "k1")
        #expect(Codex.consumeParams(creditID: nil, idempotencyKey: "k2")["creditId"] == nil)

        #expect(try Codex.parseResetOutcome(Data(#"{"outcome": "reset"}"#.utf8)) == .reset)
        #expect(try Codex.parseResetOutcome(Data(#"{"outcome": "alreadyRedeemed"}"#.utf8)).spent)
        #expect(!(try Codex.parseResetOutcome(Data(#"{"outcome": "nothingToReset"}"#.utf8)).spent))
        #expect(!(try Codex.parseResetOutcome(Data(#"{"outcome": "noCredit"}"#.utf8)).spent))
        // An answer this build does not know is no verdict, not a "nothing spent".
        #expect(throws: Codex.CodexError.self) { try Codex.parseResetOutcome(Data(#"{"outcome": "queued"}"#.utf8)) }
        #expect(throws: Codex.CodexError.self) { try Codex.parseResetOutcome(Data("{}".utf8)) }
    }
}

@Suite struct PaceTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func weekly(used: Double, resetIn: TimeInterval, forecast: Forecast? = nil) -> LimitWindow {
        LimitWindow(id: "7d", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(resetIn),
                    duration: 7 * 86_400, forecast: forecast)
    }

    @Test func proxyForecastWinsAndProjectsFullBeforeReset() throws {
        let full = now.addingTimeInterval(23.7 * 3600)
        let window = weekly(used: 51, resetIn: 56.8 * 3600,
                            forecast: Forecast(ratePerHour: 1.98, reachesThresholdAt: full, threshold: 98))
        let pace = try #require(PaceModel.pace(for: window, samples: [], now: now))
        #expect(pace.basis == .proxyForecast)
        #expect(pace.fullAt == full)
        #expect(abs(pace.even - 66.2) < 0.2)
        #expect(pace.atReset == 100)
    }

    @Test func negligibleForecastFallsBackToWindowAverage() throws {
        let window = weekly(used: 17, resetIn: 94.8 * 3600,
                            forecast: Forecast(ratePerHour: 1e-64, reachesThresholdAt: nil, threshold: 98))
        let pace = try #require(PaceModel.pace(for: window, samples: [], now: now))
        #expect(pace.basis == .windowAverage)
        #expect(pace.fullAt == nil)
        #expect(pace.atReset > 17 && pace.atReset < 98)
    }

    @Test func measuredRateUsesRecentSamplesWithinWindow() throws {
        let samples = [
            Sample(time: now.addingTimeInterval(-3000), values: ["7d": 80]),  // previous window
            Sample(time: now.addingTimeInterval(-2400), values: ["7d": 10]),
            Sample(time: now.addingTimeInterval(-1200), values: ["7d": 15]),
        ]
        let rate = try #require(PaceModel.recentRate(samples: samples, window: "7d", value: 20, now: now))
        #expect(abs(rate * 3600 - 15) < 0.01)  // 10 → 20 in 40 minutes
    }

    @Test func measuredRateStopsAtAResetBetweenSamples() throws {
        let samples = [
            Sample(time: now.addingTimeInterval(-1500), values: ["5h": 5]),  // previous window
            Sample(time: now.addingTimeInterval(-1200), values: ["5h": 0]),
            Sample(time: now.addingTimeInterval(-600), values: ["5h": 10]),
        ]
        let rate = try #require(PaceModel.recentRate(samples: samples, window: "5h", value: 20, now: now))
        #expect(abs(rate * 3600 - 60) < 0.01)  // 0 → 20 in 20 minutes
        let bounded = try #require(PaceModel.recentRate(samples: samples, window: "5h", value: 20, now: now,
                                                        windowStart: now.addingTimeInterval(-900)))
        #expect(abs(bounded * 3600 - 60) < 0.01)  // 10 → 20 in 10 minutes
    }

    @Test func measuredRateToleratesSmallWobbleAndClampsNetDrop() throws {
        let samples = [
            Sample(time: now.addingTimeInterval(-1800), values: ["5h": 10.0]),
            Sample(time: now.addingTimeInterval(-1200), values: ["5h": 14.0]),
            Sample(time: now.addingTimeInterval(-600), values: ["5h": 13.7]),
            Sample(time: now.addingTimeInterval(60), values: ["5h": 99.0]),
        ]
        let rate = try #require(PaceModel.recentRate(samples: samples, window: "5h", value: 16.0, now: now))
        #expect(abs(rate * 3600 - 12.0) < 0.01)

        let wobbledDown = [Sample(time: now.addingTimeInterval(-1200), values: ["5h": 10.2])]
        let clamped = try #require(PaceModel.recentRate(samples: wobbledDown, window: "5h", value: 10.0, now: now))
        #expect(clamped == 0)
    }

    @Test func paceUsesObservedAtInsteadOfClockDrift() throws {
        let observedAt = now.addingTimeInterval(-240)
        let window = LimitWindow(id: "5h", title: "5-hour", used: 30, resetsAt: now.addingTimeInterval(3600),
                                 duration: 5 * 3600)
        let samples = [
            Sample(time: observedAt.addingTimeInterval(-1800), values: ["5h": 20]),
            Sample(time: observedAt, values: ["5h": 30]),
        ]
        let pace = try #require(PaceModel.pace(for: window, samples: samples, now: now, observedAt: observedAt))
        #expect(pace.basis == .recent)
        #expect(abs((pace.ratePerHour ?? 0) - 20) < 0.01)
    }

    @Test func staleCutoffFollowsTheUsageCheckInterval() {
        #expect(Levels.staleAfter(probeInterval: 0) == 180)
        #expect(Levels.staleAfter(probeInterval: 60) == 180)
        #expect(Levels.staleAfter(probeInterval: 600) == 1260)
        var account = AccountSnapshot(id: "a", provider: .claude)
        account.windows = [weekly(used: 40, resetIn: 3600)]
        account.fetchedAt = now.addingTimeInterval(-400)
        #expect(account.isStale(at: now))
        account.staleAfter = Levels.staleAfter(probeInterval: 300)
        #expect(!account.isStale(at: now))
    }

    @Test func tiersFollowPeakWindow() {
        var account = AccountSnapshot(id: "a", provider: .claude)
        account.fetchedAt = now
        account.windows = [weekly(used: 91, resetIn: 3600), LimitWindow(id: "5h", title: "5-hour", used: 10,
                                                                         resetsAt: nil, duration: 18_000)]
        #expect(account.tier(at: now) == .high)
        account.fetchedAt = now.addingTimeInterval(-600)
        #expect(account.tier(at: now) == nil)  // stale readings carry no tier
    }

    func session(used: Double, resetIn: TimeInterval?) -> LimitWindow {
        LimitWindow(id: "5h", title: "5-hour", used: used, resetsAt: resetIn.map { now.addingTimeInterval($0) },
                    duration: 18_000)
    }

    /// After a banked reset the weekly window is low again while the session can fill within hours.
    @Test func theHeadlineCountsDownToTheWindowItShows() {
        var account = AccountSnapshot(id: "a", provider: .claude)
        account.windows = [session(used: 98, resetIn: 3 * 3600), weekly(used: 17, resetIn: 61 * 3600)]
        #expect(account.peak == 98)
        #expect(account.headlineReset() == now.addingTimeInterval(3 * 3600))

        // Not full: still the reset of the window the figure is taken from.
        account.windows = [session(used: 41, resetIn: 2 * 3600), weekly(used: 35, resetIn: 99 * 3600)]
        #expect(account.headlineReset() == now.addingTimeInterval(2 * 3600))
        account.windows = [session(used: 12, resetIn: 2 * 3600), weekly(used: 86, resetIn: 29 * 3600)]
        #expect(account.headlineReset() == now.addingTimeInterval(29 * 3600))
    }

    @Test func aFullAccountCountsDownToWhenItIsUsableAgain() {
        var account = AccountSnapshot(id: "a", provider: .claude)
        // Both windows are exhausted: the session's reset alone does not bring the account back.
        account.windows = [session(used: 99, resetIn: 3600), weekly(used: 98, resetIn: 40 * 3600)]
        #expect(account.headlineReset() == now.addingTimeInterval(40 * 3600))
        // A full window that states no reset says nothing about when; the figure's own window is all there is.
        account.windows = [session(used: 99, resetIn: nil), weekly(used: 20, resetIn: 40 * 3600)]
        #expect(account.headlineReset() == nil)
        account.windows = []
        #expect(account.headlineReset() == nil)
    }

    @Test func eachWindowHasItsOwnLevel() {
        #expect(session(used: 98, resetIn: 60).tier() == .full)
        #expect(weekly(used: 17, resetIn: 60).tier() == .ok)
        #expect(weekly(used: 93, resetIn: 60).tier(full: 95) == .high)
        #expect(weekly(used: 96, resetIn: 60).tier(full: 95) == .full)
        #expect(LimitWindow(id: "7d", title: "Weekly", used: nil, resetsAt: nil, duration: nil).tier() == nil)
    }

    @Test func poolSummaryEqualityAndHashTrackNextLimitDetails() {
        let at = now.addingTimeInterval(3600)
        let a = PoolSummary(claudeLeft: 50, exhausted: false, freeAgainAt: nil,
                            nextLimit: (account: "a", window: "5h", at: at))
        let b = PoolSummary(claudeLeft: 50, exhausted: false, freeAgainAt: nil,
                            nextLimit: (account: "b", window: "5h", at: at))
        let c = PoolSummary(claudeLeft: 50, exhausted: false, freeAgainAt: nil,
                            nextLimit: (account: "a", window: "7d", at: at))
        let d = PoolSummary(claudeLeft: 50, exhausted: false, freeAgainAt: nil,
                            nextLimit: (account: "a", window: "5h", at: at),
                            nextRotation: (account: "a", window: "7d", at: at))
        let same = PoolSummary(claudeLeft: 50, exhausted: false, freeAgainAt: nil,
                               nextLimit: (account: "a", window: "5h", at: at))
        #expect(a != b)
        #expect(a != c)
        #expect(a != d)
        #expect(a == same)
        #expect(a.hashValue == same.hashValue)
    }

    @Test func claudeLeftUsesWeeklyOnlyAndSeparatesPoolRotationFromWalls() throws {
        var personal = AccountSnapshot(id: "personal", provider: .claude)
        personal.fetchedAt = now
        personal.windows = [
            LimitWindow(id: "5h", title: "5-hour", used: 95, resetsAt: now.addingTimeInterval(2 * 3600),
                        duration: 5 * 3600),
            LimitWindow(id: "7d", title: "Weekly", used: 80, resetsAt: now.addingTimeInterval(40 * 3600),
                        duration: 7 * 86_400,
                        forecast: Forecast(ratePerHour: 10, reachesThresholdAt: now.addingTimeInterval(1.8 * 3600),
                                           threshold: 98)),
        ]
        var work = AccountSnapshot(id: "work", provider: .claude)
        work.fetchedAt = now
        work.windows = [
            LimitWindow(id: "7d", title: "Weekly", used: 20, resetsAt: now.addingTimeInterval(90 * 3600),
                        duration: 7 * 86_400),
        ]
        var gemini = AccountSnapshot(id: "google.gemini", provider: .google)
        gemini.fetchedAt = now
        gemini.windows = [
            LimitWindow(id: "5h", title: "5-hour", used: 80, resetsAt: now.addingTimeInterval(4 * 3600),
                        duration: 5 * 3600),
        ]
        let geminiSamples = [
            Sample(time: now.addingTimeInterval(-1800), values: ["5h": 60]),
            Sample(time: now, values: ["5h": 80]),
        ]
        let summary = PoolSummary.make(accounts: [personal, work, gemini],
                                       history: History(accounts: ["google.gemini": geminiSamples]),
                                       now: now, threshold: 98)
        // Weekly left averages (20, 80) = 50% (not distorted by Personal's 95% 5h spike).
        #expect(summary.claudeLeft == 50)
        // Personal's 98% projection is a routine rotation while Work has headroom; Gemini's 100% is the real wall.
        #expect(summary.nextRotation?.account == "personal")
        #expect(summary.nextLimit?.account == "google.gemini")
    }
}

@Suite struct HistoryTests {
    @Test func recordsChangesAndHeartbeatsOnly() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var account = AccountSnapshot(id: "a", provider: .claude)
        account.windows = [LimitWindow(id: "7d", title: "Weekly", used: 10, resetsAt: nil, duration: nil)]
        var history = History()
        for minute in 0..<30 {
            let now = start.addingTimeInterval(TimeInterval(minute * 60))
            account.fetchedAt = now
            history.record([account], now: now)
        }
        // Flat for 29 minutes: the first sample plus two 10-minute heartbeats.
        #expect(history.samples("a").count == 3)
        account.windows[0].used = 11
        let later = start.addingTimeInterval(30 * 60)
        account.fetchedAt = later
        history.record([account], now: later)
        #expect(history.samples("a").count == 4)
    }

    @Test func roundTripsThroughJSON() throws {
        var history = History()
        history.accounts["a"] = [Sample(time: Date(timeIntervalSince1970: 1_000), values: ["7d": 1])]
        let decoded = try JSONDecoder().decode(History.self, from: JSONEncoder().encode(history))
        #expect(decoded.samples("a") == history.samples("a"))
    }

    @Test func stampsSamplesWithFetchedAtAndSkipsRepeatedCachedReadings() {
        let fetched = Date(timeIntervalSince1970: 2_000_000_000)
        var account = AccountSnapshot(id: "google.gemini", provider: .google)
        account.fetchedAt = fetched
        account.staleAfter = GoogleAI.interval * 2 + 60
        account.windows = [LimitWindow(id: "5h", title: "5-hour", used: 25, resetsAt: nil, duration: 5 * 3600)]

        var history = History()
        history.record([account], now: fetched)
        history.record([account], now: fetched.addingTimeInterval(60))
        history.record([account], now: fetched.addingTimeInterval(240))
        #expect(history.samples("google.gemini").count == 1)
        #expect(history.samples("google.gemini").first?.time == fetched)

        let heartbeatAt = fetched.addingTimeInterval(History.heartbeat + 60)
        account.fetchedAt = heartbeatAt
        history.record([account], now: heartbeatAt)
        #expect(history.samples("google.gemini").count == 2)
        #expect(history.samples("google.gemini").last?.time == heartbeatAt)
    }

    @Test func burnedSumsRisesAndResetsAcrossRange() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let samples = [
            Sample(time: now.addingTimeInterval(-3600), values: ["7d": 50]),
            Sample(time: now.addingTimeInterval(-2400), values: ["7d": 49]),  // wobble ignored
            Sample(time: now.addingTimeInterval(-1800), values: ["7d": 62]),  // +12
            Sample(time: now.addingTimeInterval(-1200), values: ["7d": 5]),   // reset +5
        ]
        let history = History(accounts: ["openai": samples])
        let burned = history.burned(account: "openai", window: "7d", over: 7200, current: 11, now: now)
        #expect(burned == 23)  // 12 + 5 + (11 - 5)
    }
}

@Suite struct AlertTests {
    let now = Date()

    func account(_ used: Double) -> AccountSnapshot {
        var snapshot = AccountSnapshot(id: "a", provider: .claude)
        snapshot.fetchedAt = now
        snapshot.windows = [LimitWindow(id: "7d", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(3600),
                                        duration: 7 * 86_400)]
        return snapshot
    }

    func evaluate(_ accounts: [AccountSnapshot], up: Bool = true, restarting: Bool = false, latest: String? = nil,
                  previous: AlertState?) -> (AlertState, [Notice]) {
        Alerts.evaluate(accounts: accounts, proxyUp: up, proxyRestarting: restarting, latestTeamClaude: latest,
                        installedTeamClaude: "1.1.26", previous: previous, now: now, label: { $0 })
    }

    func staleAccount(_ used: Double) -> AccountSnapshot {
        var snapshot = account(used)
        snapshot.fetchedAt = now.addingTimeInterval(-3600)
        return snapshot
    }

    @Test func firstRunRecordsWithoutNotifying() {
        let (state, notices) = evaluate([account(99)], latest: "1.1.29", previous: nil)
        #expect(notices.isEmpty)
        #expect(state.tiers["a"] == .full)
        #expect(state.announcedUpdate == "1.1.29")
    }

    @Test func notifiesOnTierChangesExhaustionProxyAndUpdates() {
        let (s1, _) = evaluate([account(50)], latest: "1.1.26", previous: nil)
        let (s2, n2) = evaluate([account(92)], previous: s1)
        #expect(n2.map(\.body) == ["Weekly limit at 92%."])
        let (s3, n3) = evaluate([account(99)], up: false, latest: "1.1.29", previous: s2)
        #expect(n3.map(\.title) == ["a", "No Claude capacity left", "TeamClaude 1.1.29 available"])
        let (s4, n4) = evaluate([account(99)], up: false, latest: "1.1.29", previous: s3)
        #expect(n4.map(\.body) == ["Not responding."])  // the second failed read in a row
        let (s5, n5) = evaluate([account(99)], up: false, latest: "1.1.29", previous: s4)
        #expect(n5.isEmpty)
        let (_, n6) = evaluate([account(99)], latest: "1.1.29", previous: s5)
        #expect(n6.map(\.body) == ["Responding again."])
    }

    @Test func staleReadingsDoNotReannounceExhaustion() {
        let (s1, _) = evaluate([account(50)], previous: nil)
        let (s2, n2) = evaluate([account(99)], previous: s1)
        #expect(n2.map(\.title).contains("No Claude capacity left"))
        let (s3, _) = evaluate([staleAccount(99)], previous: s2)
        #expect(s3.exhausted)
        let (_, n4) = evaluate([account(99)], previous: s3)
        #expect(n4.isEmpty)
    }

    @Test func singleFailureAndOwnRestartsStayQuiet() {
        let (s1, _) = evaluate([account(50)], previous: nil)
        let (s2, n2) = evaluate([account(50)], up: false, previous: s1)
        #expect(n2.isEmpty)
        let (s3, n3) = evaluate([account(50)], previous: s2)
        #expect(n3.isEmpty)
        var state = s3
        for _ in 0..<5 {
            let (next, notices) = evaluate([account(50)], up: false, restarting: true, previous: state)
            #expect(notices.isEmpty)
            state = next
        }
        let (_, n4) = evaluate([account(50)], previous: state)
        #expect(n4.isEmpty)
    }

    @Test func firstSuccessfulUpdateCheckOnlyRecords() {
        let (s1, _) = evaluate([account(50)], previous: nil)  // the release check has not answered yet
        let (s2, n2) = evaluate([account(50)], latest: "1.1.29", previous: s1)
        #expect(n2.isEmpty)
        #expect(s2.announcedUpdate == "1.1.29")
        let (_, n3) = evaluate([account(50)], latest: "1.1.30", previous: s2)
        #expect(n3.map(\.title) == ["TeamClaude 1.1.30 available"])
    }

    @Test func leavingFullForHighAnnouncesReturn() {
        let (s1, _) = evaluate([account(99)], previous: nil)
        let (_, n2) = evaluate([account(93)], previous: s1)
        #expect(n2.map(\.body) == ["Back in rotation. Weekly at 93%."])
    }

    @Test func directProvidersUse100PercentThresholdAndAvailableAgainCopy() {
        func codex(_ used: Double) -> AccountSnapshot {
            var snapshot = AccountSnapshot(id: "openai", provider: .codex)
            snapshot.fetchedAt = now
            snapshot.windows = [LimitWindow(id: "7d", title: "Weekly", used: used,
                                            resetsAt: now.addingTimeInterval(3600), duration: 7 * 86_400)]
            return snapshot
        }
        let (s1, _) = evaluate([codex(50)], previous: nil)
        let (s2, n2) = evaluate([codex(98)], previous: s1)
        // 98% is high (not full) for direct providers.
        #expect(s2.tiers["openai"] == .high)
        #expect(n2.map(\.body) == ["Weekly limit at 98%."])
        let (s3, n3) = evaluate([codex(100)], previous: s2)
        #expect(s3.tiers["openai"] == .full)
        #expect(n3.first?.body.contains("Weekly limit reached.") == true)
        let (_, n4) = evaluate([codex(94)], previous: s3)
        #expect(n4.map(\.body) == ["Available again. Weekly at 94%."])
    }
}

/// The redeem call against a stand-in app server: a shell script that speaks just enough of the
/// protocol. No real Codex login is touched and nothing is spent.
@Suite struct CodexRedeemTests {
    /// Writes a fake `codex` that answers `initialize`, then answers the redeem request with `reply`
    /// (a shell command) after logging the request line.
    func fakeServer(reply: String) throws -> (path: String, log: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex")
        let log = dir.appendingPathComponent("request.log")
        let body = """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
            *'rateLimitResetCredit'*) printf '%s\\n' "$line" > "$REQUEST_LOG"; \(reply) ;;
          esac
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, log)
    }

    func environment(_ log: URL) -> [String: String] { ["PATH": "/usr/bin:/bin", "REQUEST_LOG": log.path] }

    @Test func sendsTheChosenCreditAndKeyAndReadsTheVerdict() async throws {
        let server = try fakeServer(reply: #"echo '{"id":2,"result":{"outcome":"reset"}}'"#)
        let outcome = try await Codex.consumeResetCredit(codex: server.path, environment: environment(server.log),
                                                         creditID: "credit-1", idempotencyKey: "key-1", timeout: 10)
        #expect(outcome == .reset)
        let sent = try JSONValue.parse(try Data(contentsOf: server.log))
        #expect(sent["method"]?.string == "account/rateLimitResetCredit/consume")
        #expect(sent["params"]?["creditId"]?.string == "credit-1")
        #expect(sent["params"]?["idempotencyKey"]?.string == "key-1")
    }

    @Test func aDeclineIsAVerdictThatSpendsNothing() async throws {
        let server = try fakeServer(reply: #"echo '{"id":2,"result":{"outcome":"nothingToReset"}}'"#)
        let outcome = try await Codex.consumeResetCredit(codex: server.path, environment: environment(server.log),
                                                         creditID: nil, idempotencyKey: "key-2", timeout: 10)
        #expect(outcome == .nothingToReset)
        #expect(!outcome.spent)
        // With no credit named, the server picks: the request must not carry an id.
        #expect(try JSONValue.parse(try Data(contentsOf: server.log))["params"]?["creditId"] == nil)
    }

    @Test func anErrorOrSilenceIsNoVerdict() async throws {
        let failing = try fakeServer(reply: #"echo '{"id":2,"error":{"code":-32000,"message":"backend unavailable"}}'"#)
        await #expect(throws: Codex.CodexError.self) {
            _ = try await Codex.consumeResetCredit(codex: failing.path, environment: environment(failing.log),
                                                   creditID: "credit-1", idempotencyKey: "key-3", timeout: 10)
        }
        let silent = try fakeServer(reply: "sleep 30")
        let start = Date()
        await #expect(throws: Codex.CodexError.self) {
            _ = try await Codex.consumeResetCredit(codex: silent.path, environment: environment(silent.log),
                                                   creditID: "credit-1", idempotencyKey: "key-4", timeout: 1)
        }
        #expect(Date().timeIntervalSince(start) < 8)
    }
}

@Suite struct ShellTests {
    @Test func timeoutKillsAProcessGroupThatIgnoresSIGTERM() async throws {
        let start = Date()
        let result = try await Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 1)
        #expect(result.timedOut)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed > 3 && elapsed < 5.5)  // SIGKILL after the grace period, before the hard deadline
    }

    @Test func timeoutReturnsWhileAJobInAnotherGroupHoldsThePipes() async throws {
        let start = Date()
        // Job control gives the background sleep its own group, out of reach of the group signals.
        let result = try await Shell.run("/bin/sh", ["-c", "set -m; sleep 9 & sleep 9"], timeout: 1)
        #expect(result.timedOut)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed > 5 && elapsed < 8.5)  // the hard deadline, not the 9 s sleep
    }

    @Test func stopOnStderrEndsAWaitingChildEarlyWithoutTimingOut() async throws {
        let start = Date()
        let result = try await Shell.run(
            "/bin/sh", ["-c", "printf 'Authentication required\\n' >&2; sleep 30"], timeout: 20,
            stopOnStderr: { $0.contains("Authentication required") })
        let elapsed = Date().timeIntervalSince(start)
        #expect(!result.timedOut)
        #expect(result.errorOutput.contains("Authentication required"))
        #expect(elapsed < 5)
    }

    @Test func concurrentSpawnDoesNotLeakPipeDescriptors() async throws {
        let handle = ProcessHandle()
        let sleeper = Task {
            try await Shell.run("/bin/sleep", ["6"], timeout: 10, handle: handle)
        }
        defer { handle.cancel() }

        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    let result = try await Shell.run(
                        "/bin/sh", ["-c", "printf 'ok-\(index)\\n'; printf 'err-\(index)\\n' >&2"], timeout: 10)
                    #expect(!result.timedOut)
                    #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok-\(index)")
                    #expect(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "err-\(index)")
                }
            }
            try await group.waitForAll()
        }
        #expect(Date().timeIntervalSince(start) < 3)
        handle.cancel()
        _ = try? await sleeper.value
    }
}

@Suite struct UpdateTests {
    @Test func semverComparison() {
        #expect(SemVer.isNewer("1.1.29", than: "1.1.26"))
        #expect(SemVer.isNewer("1.2.0", than: "1.1.99"))
        #expect(!SemVer.isNewer("1.1.26", than: "1.1.26"))
        #expect(!SemVer.isNewer("1.1.26-rc.1", than: "1.1.26"))
    }

    @Test func refusesNonReleaseVersions() {
        #expect(throws: TeamClaudeUpdates.UpdateError.self) {
            try TeamClaudeUpdates.installArguments(version: "99.0.0 || npm:evil", installDir: "/tmp/x")
        }
        #expect(throws: TeamClaudeUpdates.UpdateError.self) {
            try TeamClaudeUpdates.installArguments(version: "2.0.0", installDir: "/tmp/x", package: "evil-pkg")
        }
        let legacyArgs = try? TeamClaudeUpdates.installArguments(version: "1.1.29", installDir: "/tmp/x")
        #expect(legacyArgs == ["install", "--prefix", "/tmp/x", "--no-audit", "--no-fund", "@karpeleslab/teamclaude@1.1.29"])
        let routerArgs = try? TeamClaudeUpdates.installArguments(version: "2.0.0", installDir: "/tmp/x",
                                                                 package: "teamrouter")
        #expect(routerArgs == ["install", "--prefix", "/tmp/x", "--no-audit", "--no-fund", "teamrouter@2.0.0"])
    }

    @Test func detectsInstalledPackageFromInstallDirAndCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-upd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let installDir = root.appendingPathComponent("prefix")
        let legacyDir = installDir.appendingPathComponent("node_modules/@karpeleslab/teamclaude")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try Data(#"{"name": "@karpeleslab/teamclaude", "version": "1.1.31"}"#.utf8)
            .write(to: legacyDir.appendingPathComponent("package.json"))

        let legacy = try #require(TeamClaudeUpdates.installedPackage(installDir: installDir.path))
        #expect(legacy == .init(name: "@karpeleslab/teamclaude", version: "1.1.31", inInstallDir: true))

        // Transition via hoisted `teamrouter` in the same prefix prefers `teamrouter`.
        let routerDir = installDir.appendingPathComponent("node_modules/teamrouter")
        try FileManager.default.createDirectory(at: routerDir, withIntermediateDirectories: true)
        try Data(#"{"name": "teamrouter", "version": "2.0.0"}"#.utf8)
            .write(to: routerDir.appendingPathComponent("package.json"))

        let router = try #require(TeamClaudeUpdates.installedPackage(installDir: installDir.path))
        #expect(router == .init(name: "teamrouter", version: "2.0.0", inInstallDir: true))

        // Global symlink outside installDir follows the shim to `teamrouter`.
        let globalRoot = root.appendingPathComponent("global/lib/node_modules")
        let globalShim = globalRoot.appendingPathComponent("@karpeleslab/teamclaude")
        let globalShimSrc = globalShim.appendingPathComponent("src")
        let globalRouter = globalRoot.appendingPathComponent("teamrouter")
        try FileManager.default.createDirectory(at: globalShimSrc, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalRouter, withIntermediateDirectories: true)
        try Data(#"{"name": "@karpeleslab/teamclaude", "version": "1.99.0"}"#.utf8)
            .write(to: globalShim.appendingPathComponent("package.json"))
        try Data(#"{"name": "teamrouter", "version": "2.1.0"}"#.utf8)
            .write(to: globalRouter.appendingPathComponent("package.json"))
        let entry = globalShimSrc.appendingPathComponent("index.js")
        try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
        let bin = root.appendingPathComponent("teamclaude")
        try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: entry)

        let globalPkg = try #require(TeamClaudeUpdates.installedPackage(cli: bin.path, installDir: "/nonexistent"))
        #expect(globalPkg == .init(name: "teamrouter", version: "2.1.0", inInstallDir: false))
    }
}

@Suite struct FormatTests {
    @Test func durations() {
        #expect(Format.duration(56.8 * 3600) == "2d 8h")
        #expect(Format.duration(23.7 * 3600) == "23h 42m")
        #expect(Format.duration(3600) == "1h")
        #expect(Format.duration(59) == "59s")
    }

    @Test func countdowns() {
        #expect(Format.countdown(159.2) == "2m 40s")
        #expect(Format.countdown(60) == "1m 0s")
        #expect(Format.countdown(0.4) == "1s")
        #expect(Format.countdown(-5) == "0s")
        #expect(Format.countdown(1500) == "25m")
    }

    @Test func counts() {
        #expect(Format.count(126_139_292) == "126M")
        #expect(Format.count(3_140_870) == "3.1M")
        #expect(Format.count(18_782) == "18.8K")
        #expect(Format.count(2_000_000) == "2M")
        #expect(Format.count(812) == "812")
    }

    @Test func modelNames() {
        #expect(Format.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(Format.modelName("claude-haiku-5-5-20260101") == "Haiku 5.5")
    }
}

/// Updating from 1.0, when the app was called "Usage Bar".
@Suite struct LegacyInstallTests {
    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func movesTheLegacyFolderWithItsFiles() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("usage-bar")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("config.json"))
        let current = root.appendingPathComponent("nested/runout-bar")

        #expect(LegacyInstall.move(legacy, to: current))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("config.json").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func keepsTheCurrentFolderWhenBothExist() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("usage-bar")
        let current = root.appendingPathComponent("runout-bar")
        for (dir, text) in [(legacy, "old"), (current, "new")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: dir.appendingPathComponent("config.json"))
        }

        #expect(!LegacyInstall.move(legacy, to: current))
        #expect(try String(contentsOf: current.appendingPathComponent("config.json"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func doesNothingWithoutALegacyFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("runout-bar")

        #expect(!LegacyInstall.move(root.appendingPathComponent("usage-bar"), to: current))
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }

    @Test func copiesOnlyMissingSettingsAndNeverTheLoginItemMark() {
        let copied = LegacyInstall.settingsToCopy(
            from: ["menuBarStyle": "bars", "notifications": false, "loginItemInitialized": true],
            into: ["menuBarStyle": "numbers"])

        #expect(copied.keys.sorted() == ["notifications"])
        #expect(copied["notifications"] as? Bool == false)
    }
}
