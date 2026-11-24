import Foundation
import Testing
@testable import RunoutCore

private let paris: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}()

/// "2026-11-12 14:00" in Paris. 2026-11-12 is a Thursday.
private func at(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = paris
    formatter.timeZone = paris.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

private func sample(_ time: String, _ used: Double) -> Sample { Sample(time: at(time), values: ["7d": used]) }

private func claude(_ id: String, _ used: Double, resets: String, fetched: Date) -> AccountSnapshot {
    var account = AccountSnapshot(id: id, provider: .claude)
    account.fetchedAt = fetched
    account.windows = [LimitWindow(id: "7d", title: "Weekly", used: used, resetsAt: at(resets), duration: 7 * 86_400)]
    return account
}

private func near(_ date: Date?, _ expected: Date) -> Bool {
    guard let date else { return false }
    return abs(date.timeIntervalSince(expected)) < 1
}

@Suite struct WorkWeekTests {
    let week = WorkWeek()
    let far = at("2026-12-31 00:00")

    @Test func countsOnlyWeekdayWorkHours() {
        #expect(week.workTime(from: at("2026-11-12 14:00"), to: at("2026-11-13 19:00"), calendar: paris) == 15 * 3600)
        #expect(week.workTime(from: at("2026-11-13 18:00"), to: at("2026-11-16 10:00"), calendar: paris) == 2 * 3600)
        #expect(week.date(addingWork: 6 * 3600, to: at("2026-11-12 14:00"), calendar: paris, limit: far)
            == at("2026-11-13 10:00"))
        // From Saturday the next work hour is Monday morning.
        #expect(week.date(addingWork: 3600, to: at("2026-11-14 12:00"), calendar: paris, limit: far)
            == at("2026-11-16 10:00"))
        #expect(week.date(addingWork: 3600, to: at("2026-11-14 12:00"), calendar: paris, limit: at("2026-11-16 09:30"))
            == nil)
    }

    @Test func targetIsTheEndOfFridayUntilItPasses() {
        #expect(week.weekEnd(after: at("2026-11-12 14:00"), calendar: paris) == at("2026-11-13 19:00"))
        #expect(week.weekEnd(after: at("2026-11-13 18:59"), calendar: paris) == at("2026-11-13 19:00"))
        #expect(week.weekEnd(after: at("2026-11-13 19:30"), calendar: paris) == at("2026-11-20 19:00"))
        #expect(week.weekEnd(after: at("2026-11-15 10:00"), calendar: paris) == at("2026-11-20 19:00"))
    }

    @Test func findsPreviousWorkdayEnd() {
        // Thursday -> Wednesday 19:00
        #expect(week.previousWorkdayEnd(before: at("2026-11-12 14:00"), calendar: paris) == at("2026-11-11 19:00"))
        // Monday -> Friday 19:00
        #expect(week.previousWorkdayEnd(before: at("2026-11-16 09:30"), calendar: paris) == at("2026-11-13 19:00"))
        // Sunday -> Friday 19:00
        #expect(week.previousWorkdayEnd(before: at("2026-11-15 12:00"), calendar: paris) == at("2026-11-13 19:00"))
    }

    @Test func summarizesTheWeek() {
        #expect(week.summary == "Mon–Fri 09:00–19:00")
        #expect(WorkWeek(days: [2, 4, 6], start: 8 * 60 + 30, end: 1440).summary == "Mon, Wed, Fri 08:30–24:00")
    }

    @Test func readsTheWorkWeekFromConfig() throws {
        let json = #"{"workWeek": {"days": ["Mon", "Tue", "Wed", "Thu"], "start": "08:30", "end": "18:00"}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.workWeek.weekEnd(after: at("2026-11-12 14:00"), calendar: paris) == at("2026-11-12 18:00"))
        #expect(config.workWeek.workTime(from: at("2026-11-12 08:00"), to: at("2026-11-12 09:00"), calendar: paris)
            == 1800)
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8)).workWeek == WorkWeek())
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppConfig.self, from: Data(#"{"workWeek": {"end": "25:00"}}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppConfig.self, from: Data(#"{"workWeek": {"days": []}}"#.utf8))
        }
    }
}

@Suite struct RunOutTests {
    let now = at("2026-11-12 14:00")  // Thursday

    func make(_ accounts: [AccountSnapshot], _ history: History, now: Date? = nil) -> PoolRunOut? {
        PoolRunOut.make(accounts: accounts, history: history, now: now ?? self.now, threshold: 98, week: WorkWeek(),
                        calendar: paris)
    }

    /// A burns 15 points between Wednesday evening and now, B 3 points overnight: 18 points over 6 work hours.
    var threePointsAnHour: History {
        History(accounts: [
            "a": [sample("2026-11-11 18:00", 65), sample("2026-11-12 09:00", 65), sample("2026-11-12 13:00", 77),
                  sample("2026-11-12 14:00", 80)],
            "b": [sample("2026-11-11 18:00", 87), sample("2026-11-12 02:00", 90), sample("2026-11-12 14:00", 90)],
        ])
    }

    @Test func projectsOverWorkHoursOnly() throws {
        var codex = AccountSnapshot.unavailable("openai", provider: .codex, error: "offline")
        codex.fetchedAt = now
        let accounts = [claude("a", 80, resets: "2026-11-14 21:00", fetched: now),
                        claude("b", 90, resets: "2026-11-16 11:00", fetched: now), codex]
        let runOut = try #require(make(accounts, threePointsAnHour))
        #expect(abs(runOut.ratePerWorkHour - 3) < 1e-9)
        #expect(runOut.measuredOver == 6 * 3600)
        // 18 + 8 points left at 3 an hour is 8h 40m of work: the rest of Thursday, then Friday morning.
        // A calendar-hour projection would say Thursday 22:40.
        #expect(near(runOut.at, at("2026-11-13 12:40")))
        #expect(runOut.target == at("2026-11-13 19:00"))
        #expect(runOut.state == .short)
        #expect(near(runOut.shownDate(now: now), at("2026-11-13 12:40")))
        // 26 points over the 15 work hours to Friday 19:00.
        #expect(abs((runOut.budgetPerWorkHour ?? 0) - 26.0 / 15) < 1e-3)
    }

    @Test func aResetBeforeRunOutAddsThatAccountBack() throws {
        // A burns 10 points per work hour this morning; its week resets at 16:00 today.
        let history = History(accounts: [
            "a": [sample("2026-11-12 09:00", 40), sample("2026-11-12 14:00", 90)],
            "b": [sample("2026-11-12 09:00", 50), sample("2026-11-12 14:00", 50)],
        ])
        let accounts = [claude("a", 90, resets: "2026-11-12 16:00", fetched: now),
                        claude("b", 50, resets: "2026-11-16 11:00", fetched: now)]
        let runOut = try #require(make(accounts, history))
        // Adding up what is left (8 + 48 points) would run out Friday 09:36. With A back at 16:00, the pool has
        // 8 + 48 + 98 points: 15.4 work hours, so Monday 09:24.
        #expect(near(runOut.at, at("2026-11-16 09:24")))
        #expect(runOut.state == .lasts)
        #expect(near(runOut.shownDate(now: now), at("2026-11-16 09:24")))
    }

    @Test func paceCountsUsageAfterAResetAndSkipsTheWeekend() throws {
        let monday = at("2026-11-16 12:00")
        let history = History(accounts: ["a": [
            // The week resets Saturday 21:00; 4 points go on Sunday.
            sample("2026-11-13 09:00", 70), sample("2026-11-13 19:00", 90), sample("2026-11-15 10:00", 4),
            sample("2026-11-16 09:00", 4), sample("2026-11-16 12:00", 6),
        ]])
        let runOut = try #require(make([claude("a", 6, resets: "2026-11-21 21:00", fetched: monday)], history,
                                       now: monday))
        #expect(abs(runOut.ratePerWorkHour - 2) < 1e-9)  // 20 + 4 + 2 points over 13 work hours
        // 92 points at 2 an hour is 46 work hours: Friday 18:00, an hour before the target.
        #expect(near(runOut.at, at("2026-11-20 18:00")))
        #expect(runOut.target == at("2026-11-20 19:00"))
        #expect(runOut.state == .short)
    }

    @Test func onePointFlickerIsNotUsage() throws {
        // Live readings wobble between neighbouring values while the account climbs from 50 to 52.
        let values: [(String, Double)] = [("09:00", 50), ("09:30", 49), ("10:00", 50), ("10:30", 49), ("11:00", 50),
                                          ("12:00", 51), ("12:30", 50), ("13:00", 51), ("14:00", 52)]
        let history = History(accounts: ["a": values.map { sample("2026-11-12 " + $0.0, $0.1) }])
        let runOut = try #require(make([claude("a", 52, resets: "2026-11-14 21:00", fetched: now)], history))
        #expect(abs(runOut.ratePerWorkHour - 0.4) < 1e-9)  // 2 points over 5 work hours
    }

    @Test func runningOutTodayIsCritical() throws {
        let accounts = [claude("a", 90, resets: "2026-11-14 21:00", fetched: now),
                        claude("b", 95, resets: "2026-11-16 11:00", fetched: now)]
        let runOut = try #require(make(accounts, threePointsAnHour))
        #expect(near(runOut.at, at("2026-11-12 17:40")))  // 11 points, 3h 40m
        #expect(runOut.state == .critical)
    }

    @Test func anExhaustedPoolIsOutNow() throws {
        let accounts = [claude("a", 98, resets: "2026-11-14 21:00", fetched: now),
                        claude("b", 99, resets: "2026-11-16 11:00", fetched: now)]
        let runOut = try #require(make(accounts, threePointsAnHour))
        #expect(runOut.at == now)
        #expect(runOut.state == .critical)
    }

    @Test func idleHistoryMeansThePoolIsIdle() throws {
        let history = History(accounts: ["a": [sample("2026-11-12 08:00", 30), sample("2026-11-12 14:00", 30)]])
        let runOut = try #require(make([claude("a", 30, resets: "2026-11-14 21:00", fetched: now)], history))
        #expect(runOut.ratePerWorkHour == 0)
        #expect(runOut.at == nil)
        #expect(runOut.state == .idle)
        #expect(runOut.shownDate(now: now) == nil)
    }

    @Test func directLaneProjectsTo100PercentThreshold() throws {
        var gemini = AccountSnapshot(id: "google.gemini", provider: .google)
        gemini.title = "Gemini"
        gemini.fetchedAt = now
        gemini.windows = [LimitWindow(id: "7d", title: "Weekly", used: 90, resetsAt: at("2026-11-14 21:00"),
                                      duration: 7 * 86_400)]
        let history = History(accounts: [
            "google.gemini": [sample("2026-11-12 09:00", 65), sample("2026-11-12 14:00", 90)],
        ])
        let lane = CapacityLane(id: "google.gemini", provider: .google, title: "Gemini",
                                kind: .direct(source: "Antigravity CLI"), accounts: [gemini], threshold: 100)
        let runOut = try #require(PoolRunOut.make(lane: lane, history: history, now: now, week: WorkWeek(),
                                                  calendar: paris))
        #expect(abs(runOut.ratePerWorkHour - 5) < 1e-9)
        // 10% remaining to 100% at 5%/h = 2h -> 16:00 today (not 15:36 at 98%).
        #expect(near(runOut.at, at("2026-11-12 16:00")))
        #expect(runOut.state == .critical)
    }

    @Test func untouchedGoogleGroupIsIdleEvenWithoutHistory() throws {
        var untouched = AccountSnapshot(id: "google.claude-and-gpt", provider: .google)
        untouched.title = "Claude and GPT"
        untouched.fetchedAt = now
        untouched.windows = [LimitWindow(id: "7d", title: "Weekly", used: 0, resetsAt: nil, duration: 7 * 86_400)]
        let lane = CapacityLane(id: "google.claude-and-gpt", provider: .google, title: "Claude & GPT",
                                kind: .direct(source: "Antigravity CLI"), accounts: [untouched], threshold: 100)
        let runOut = try #require(PoolRunOut.make(lane: lane, history: History(), now: now, week: WorkWeek(),
                                                  calendar: paris))
        #expect(runOut.state == .idle)
        #expect(runOut.ratePerWorkHour == 0)
        #expect(runOut.at == nil)
    }

    @Test func recencyWeightedPaceFavorsTodayAndFlagsQuietToday() throws {
        // Prior workday (Wed 09:00..19:00 = 10h): burned 10 pts -> 1%/h.
        // Today (Thu 09:00..14:00 = 5h): burned 20 pts -> 4%/h.
        let history = History(accounts: [
            "a": [sample("2026-11-11 09:00", 10), sample("2026-11-11 19:00", 20),
                  sample("2026-11-12 09:00", 20), sample("2026-11-12 14:00", 40)],
        ])
        let runOut = try #require(make([claude("a", 40, resets: "2026-11-14 21:00", fetched: now)], history))
        #expect(runOut.paceBasis == .recencyWeighted)
        #expect(!runOut.quietToday)
        #expect(abs(runOut.ratePerWorkHour - (0.65 * 4.0 + 0.35 * 1.0)) < 1e-9)

        // When yesterday burned 10 pts and today has been flat for >= 4 work hours, quietToday is flagged.
        let quietHistory = History(accounts: [
            "a": [sample("2026-11-11 09:00", 10), sample("2026-11-11 19:00", 20),
                  sample("2026-11-12 14:00", 20)],
        ])
        let quiet = try #require(make([claude("a", 20, resets: "2026-11-14 21:00", fetched: now)], quietHistory))
        #expect(quiet.paceBasis == .recencyWeighted)
        #expect(quiet.quietToday)
        #expect(abs(quiet.ratePerWorkHour - (0.35 * 1.0)) < 1e-9)
    }

    @Test func freshlyActivatedLaneUsesActiveTodayPaceWithoutDeadDayDilution() throws {
        // Flat all of Wed (10h at 0%), then switched to it Thu morning (5h -> 15% burned).
        let history = History(accounts: [
            "a": [sample("2026-11-11 09:00", 0), sample("2026-11-11 19:00", 0),
                  sample("2026-11-12 09:00", 0), sample("2026-11-12 14:00", 15)],
        ])
        let runOut = try #require(make([claude("a", 15, resets: "2026-11-14 21:00", fetched: now)], history))
        #expect(runOut.paceBasis == .activeToday)
        #expect(runOut.measuredOver == 5 * 3600)
        #expect(abs(runOut.ratePerWorkHour - 3.0) < 1e-9)
    }

    @Test func noTimeWithoutFreshReadingsOrEnoughHistory() {
        let fresh = claude("a", 80, resets: "2026-11-14 21:00", fetched: now)
        let stale = claude("b", 90, resets: "2026-11-16 11:00", fetched: now.addingTimeInterval(-3600))
        #expect(make([fresh, stale], threePointsAnHour) == nil)
        var down = claude("b", 90, resets: "2026-11-16 11:00", fetched: now)
        down.error = "Proxy not responding"
        #expect(make([fresh, down], threePointsAnHour) == nil)
        #expect(make([fresh], History()) == nil)
        #expect(make([], threePointsAnHour) == nil)
        // 08:00 to 10:30 holds only 1.5 work hours.
        let early = at("2026-11-12 10:30")
        let short = History(accounts: ["a": [sample("2026-11-12 08:00", 60), sample("2026-11-12 10:30", 70)]])
        #expect(make([claude("a", 70, resets: "2026-11-14 21:00", fetched: early)], short, now: early) == nil)
    }
}

@Suite struct CapacityLaneTests {
    let now = at("2026-11-12 14:00")

    @Test func buildsPooledClaudeAndSeparateDirectLanes() {
        let c1 = claude("p@example.com", 70, resets: "2026-11-15 10:00", fetched: now)
        let c2 = claude("w@example.com", 40, resets: "2026-11-16 10:00", fetched: now)
        var codex = AccountSnapshot(id: "openai", provider: .codex)
        codex.fetchedAt = now
        codex.windows = [LimitWindow(id: "7d", title: "Weekly", used: 18, resetsAt: at("2026-11-17 10:00"),
                                     duration: 7 * 86_400)]
        var gemini = AccountSnapshot(id: "google.gemini", provider: .google)
        gemini.title = "Gemini"
        gemini.fetchedAt = now
        gemini.windows = [LimitWindow(id: "7d", title: "Weekly", used: 60, resetsAt: at("2026-11-16 10:00"),
                                      duration: 7 * 86_400)]

        let lanes = CapacityLane.build(accounts: [c1, c2, codex, gemini], proxyThreshold: 98) { $0.title ?? $0.id }
        #expect(lanes.map(\.id) == ["claude", "openai", "google.gemini"])
        #expect(lanes[0].kind.isPooled)
        #expect(lanes[0].accounts.count == 2)
        #expect(lanes[0].threshold == 98)
        #expect(lanes[0].weeklyLeft(at: now) == 45)  // mean of (30, 60)
        #expect(lanes[0].hasHeadroom(excluding: "p@example.com", at: now))
        #expect(!lanes[1].kind.isPooled)
        #expect(lanes[1].threshold == 100)
        #expect(!lanes[1].hasHeadroom(excluding: "openai", at: now))
    }

    @Test func globalRunOutPicksEarliestBottleneckAcrossProviders() throws {
        let c1 = claude("a", 20, resets: "2026-11-15 10:00", fetched: now)
        var gemini = AccountSnapshot(id: "google.gemini", provider: .google)
        gemini.title = "Gemini"
        gemini.fetchedAt = now
        gemini.windows = [LimitWindow(id: "7d", title: "Weekly", used: 70, resetsAt: at("2026-11-15 10:00"),
                                      duration: 7 * 86_400)]
        var untouched = AccountSnapshot(id: "google.claude-and-gpt", provider: .google)
        untouched.title = "Claude & GPT"
        untouched.fetchedAt = now
        untouched.windows = [LimitWindow(id: "7d", title: "Weekly", used: 0, resetsAt: nil, duration: 7 * 86_400)]

        let history = History(accounts: [
            "a": [sample("2026-11-12 09:00", 15), sample("2026-11-12 14:00", 20)],  // 1%/h -> lasts
            "google.gemini": [sample("2026-11-12 09:00", 50), sample("2026-11-12 14:00", 70)],  // 4%/h -> 7.5h left (Fri short)
        ])
        let lanes = CapacityLane.build(accounts: [c1, gemini, untouched], proxyThreshold: 98) { $0.title ?? $0.id }
        let global = GlobalRunOut.make(lanes: lanes, history: history, now: now, week: WorkWeek(), calendar: paris)
        #expect(global.state == .short)
        #expect(global.shortCount == 1)
        #expect(global.bottleneck?.id == "google.gemini")
        #expect(global.lanes.last?.runOut?.state == .idle)
    }
}
