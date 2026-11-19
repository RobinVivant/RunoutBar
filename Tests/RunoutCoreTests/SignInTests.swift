import Foundation
import Testing
@testable import RunoutCore

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400

private func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }

@Suite struct SignInStageTests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    func claude(expiresIn: TimeInterval? = nil, failure: SignIn.Failure? = nil) -> SignIn {
        SignIn(holder: .teamclaude, account: "ada@example.com", expiresAt: expiresIn.map(now.addingTimeInterval),
               failure: failure)
    }

    @Test func stagesFollowTheTimeLeft() {
        #expect(claude(expiresIn: 29 * day).stage(at: now) == .ok)
        #expect(claude(expiresIn: 5 * day + 60).stage(at: now) == .ok)
        #expect(claude(expiresIn: 5 * day).stage(at: now) == .soon)
        #expect(claude(expiresIn: day + 60).stage(at: now) == .soon)
        #expect(claude(expiresIn: day).stage(at: now) == .urgent)
        #expect(claude(expiresIn: 60).stage(at: now) == .urgent)
        #expect(claude(expiresIn: 0).stage(at: now) == .lapsed)
        #expect(claude(expiresIn: -hour).stage(at: now) == .lapsed)
    }

    @Test func aSignInWithoutADateIsFineUntilItIsRefused() {
        #expect(claude().stage(at: now) == .ok)
        let refused = claude(expiresIn: 20 * day, failure: SignIn.Failure(code: "refresh_rejected", detail: "x"))
        #expect(refused.stage(at: now) == .lapsed)
    }

    @Test func headlinesSayWhatAndWhen() {
        #expect(claude(expiresIn: 18 * hour).headline(now: now) == "Sign-in expires in 18h")
        #expect(claude(expiresIn: 3 * day + 2 * hour).headline(now: now) == "Sign-in expires in 3d 2h")
        #expect(claude(expiresIn: -hour).headline(now: now) == "Sign-in expired")
        #expect(claude(failure: SignIn.Failure(code: "refresh_rejected", detail: "x")).headline(now: now)
            == "Sign-in rejected")
        #expect(claude(failure: SignIn.Failure(code: "signed_out", detail: "x")).headline(now: now) == "Not signed in")
        #expect(claude(failure: SignIn.Failure(code: "account_on_hold", detail: "x")).headline(now: now)
            == "Account refused")
        let far = now.addingTimeInterval(29 * day)
        #expect(claude(expiresIn: 29 * day).headline(now: now) == "Signed in until \(Format.day(far))")
        #expect(claude().headline(now: now) == "Signed in")
    }

    @Test func explanationsNameTheDateAndTheConsequence() {
        let soon = now.addingTimeInterval(3 * day)
        let text = claude(expiresIn: 3 * day).explanation(now: now)
        #expect(text.contains(Format.dayTime(soon)))
        #expect(text.contains("leaves rotation"))

        let since = now.addingTimeInterval(-2 * hour)
        let rejected = claude(failure: SignIn.Failure(
            code: "refresh_rejected", detail: "upstream rejected its refresh token (400 invalid_grant)", since: since))
        #expect(rejected.explanation(now: now)
            == "Rejected \(Format.dayTime(since)): upstream rejected its refresh token (400 invalid_grant).")

        let held = claude(failure: SignIn.Failure(code: "account_on_hold", detail: "The account is on hold."))
        #expect(held.explanation(now: now) == "The account is on hold. Resolve it with the provider, then sign in again.")
    }

    @Test func eachHolderHasItsOwnCommand() {
        #expect(claude().loginArguments == ["login", "--oauth"])
        #expect(claude().commandLine == "teamclaude login")
        let proxyCodex = SignIn(holder: .teamclaudeCodex, account: "openai")
        #expect(proxyCodex.loginArguments == ["login", "--codex"])
        #expect(proxyCodex.commandLine == "teamclaude login --codex")
        let cli = SignIn(holder: .codex, account: "openai")
        #expect(cli.loginArguments == ["login"])
        #expect(cli.commandLine == "codex login")
        let longLived = SignIn(holder: .teamclaude, account: "ci", manual: true)
        #expect(longLived.commandLine == "teamclaude login --long-lived --name ci")
        #expect(cli.id != proxyCodex.id)
    }
}

@Suite struct SignInStatusTests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    func status(_ accounts: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["accounts": accounts, "server": ["version": "1.1.30"]])
    }

    func account(_ name: String, provider: String = "anthropic", _ extra: [String: Any] = [:]) -> [String: Any] {
        var account: [String: Any] = ["name": name, "provider": provider, "type": "oauth", "status": "active",
                                      "quota": [String: Any]()]
        for (key, value) in extra { account[key] = value }
        return account
    }

    @Test func readsTheExpiryOfAnActiveAccount() throws {
        let expiry = now.addingTimeInterval(4 * day)
        let data = try status([account("ada@example.com", ["refreshTokenExpiresAt": ms(expiry)])])
        let signIn = try #require(try TeamClaudeStatus.parse(data, config: AppConfig()).accounts.first?.signIn)
        #expect(signIn.holder == .teamclaude)
        #expect(signIn.account == "ada@example.com")
        #expect(signIn.expiresAt == expiry)
        #expect(signIn.failure == nil)
        #expect(!signIn.manual)
    }

    @Test func readsWhyAnAccountNeedsALogin() throws {
        let since = now.addingTimeInterval(-hour)
        let data = try status([account("ada@example.com", [
            "status": "error",
            "refreshTokenExpiresAt": ms(now.addingTimeInterval(-hour)),
            "errorReason": ["code": "refresh_rejected", "detail": "upstream rejected its refresh token",
                            "since": ms(since), "remedy": "teamclaude login", "link": NSNull()],
        ])])
        let failure = try #require(try TeamClaudeStatus.parse(data, config: AppConfig()).accounts.first?.signIn?.failure)
        #expect(failure.code == "refresh_rejected")
        #expect(failure.detail == "upstream rejected its refresh token")
        #expect(failure.since == since)
        #expect(failure.link == nil)
        #expect(failure.fixedBySigningIn)
    }

    @Test func anAccountInErrorWithoutAReasonStillNeedsALogin() throws {
        let data = try status([account("ada@example.com", ["status": "error"])])
        let failure = try #require(try TeamClaudeStatus.parse(data, config: AppConfig()).accounts.first?.signIn?.failure)
        #expect(failure.code == "error")
        #expect(!failure.detail.isEmpty)
    }

    @Test func aLongLivedTokenCountsDownToItsOwnDate() throws {
        let expiry = now.addingTimeInterval(200 * day)
        let data = try status([account("ci", ["longLived": true, "expiresAt": ms(expiry)])])
        let signIn = try #require(try TeamClaudeStatus.parse(data, config: AppConfig()).accounts.first?.signIn)
        #expect(signIn.expiresAt == expiry)
        #expect(signIn.manual)
    }

    @Test func codexAccountsInTheProxyAreKeptApartAndOthersSkipped() throws {
        let data = try status([
            account("ada@example.com"),
            account("key", ["type": "api"]),
            account("off@example.com", ["disabled": true, "status": "error"]),
            account("openai", provider: "codex", [
                "status": "error",
                "errorReason": ["code": "refresh_rejected", "detail": "refused", "since": ms(now),
                                "remedy": "teamclaude login --codex"],
            ]),
        ])
        let (accounts, proxy) = try TeamClaudeStatus.parse(data, config: AppConfig())
        #expect(accounts.map(\.id) == ["ada@example.com", "key"])
        #expect(accounts[0].signIn?.expiresAt == nil)
        #expect(accounts[0].signIn?.failure == nil)
        // An API key has no sign-in to lapse.
        #expect(accounts[1].signIn == nil)
        #expect(proxy.codexSignIns.map(\.id) == ["teamclaudeCodex:openai"])
        #expect(proxy.codexSignIns.first?.failure?.code == "refresh_rejected")
    }
}

@Suite struct SignInAlertTests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    func signIn(_ expiresIn: TimeInterval?, failure: SignIn.Failure? = nil, account: String = "a") -> SignIn {
        SignIn(holder: .teamclaude, account: account, expiresAt: expiresIn.map(now.addingTimeInterval), failure: failure)
    }

    func evaluate(_ signIns: [SignIn], previous: AlertState?) -> (AlertState, [Notice]) {
        Alerts.evaluate(accounts: [], signIns: signIns, proxyUp: true, latestTeamClaude: nil, installedTeamClaude: nil,
                        previous: previous, now: now, label: { "Label \($0)" })
    }

    @Test func theFirstEvaluationOnlyRecords() {
        let (state, notices) = evaluate([signIn(2 * hour)], previous: nil)
        #expect(notices.isEmpty)
        #expect(state.signIns == ["teamclaude:a": .urgent])
    }

    @Test func aStateSavedBeforeSignInsWereTrackedAnnouncesWhatIsAlreadyDue() {
        // The state file of an earlier version has no sign-in record.
        let (state, notices) = evaluate([signIn(18 * hour), signIn(20 * day, account: "b")], previous: AlertState())
        #expect(notices.count == 1)
        #expect(notices[0].title == "Label a")
        #expect(notices[0].signIn == "teamclaude:a")
        #expect(notices[0].body.hasPrefix("Sign-in expires in 18h"))
        #expect(state.signIns == ["teamclaude:a": .urgent, "teamclaude:b": .ok])
    }

    @Test func eachStageIsAnnouncedOnce() {
        var (state, notices) = evaluate([signIn(6 * day)], previous: AlertState())
        #expect(notices.isEmpty)
        (state, notices) = evaluate([signIn(4 * day)], previous: state)
        #expect(notices.map(\.body).count == 1)
        #expect(notices[0].body.contains(Format.dayTime(now.addingTimeInterval(4 * day))))
        (state, notices) = evaluate([signIn(3 * day)], previous: state)
        #expect(notices.isEmpty)
        (state, notices) = evaluate([signIn(20 * hour)], previous: state)
        #expect(notices.count == 1)
        (state, notices) = evaluate([signIn(-60)], previous: state)
        #expect(notices.map(\.body) == ["Sign-in expired. Reconnect it from Runout Bar."])
        (state, notices) = evaluate([signIn(-3600)], previous: state)
        #expect(notices.isEmpty)
        #expect(state.signIns == ["teamclaude:a": .lapsed])
    }

    @Test func aRefusalIsAnnouncedWithItsReason() {
        let refused = signIn(10 * day, failure: SignIn.Failure(code: "refresh_rejected",
                                                             detail: "upstream rejected its refresh token"))
        let (_, notices) = evaluate([refused], previous: evaluate([signIn(10 * day)], previous: AlertState()).0)
        #expect(notices.map(\.body) == ["Sign-in rejected: upstream rejected its refresh token. "
            + "Reconnect it from Runout Bar."])
    }

    @Test func aRenewalIsQuietAndTheNextExpiryWarnsAgain() {
        var (state, notices) = evaluate([signIn(-60)], previous: AlertState())
        #expect(notices.count == 1)
        (state, notices) = evaluate([signIn(30 * day)], previous: state)
        #expect(notices.isEmpty)
        #expect(state.signIns == ["teamclaude:a": .ok])
        (state, notices) = evaluate([signIn(2 * day)], previous: state)
        #expect(notices.count == 1)
    }

    @Test func aCodexAccountInTheProxyGoesByItsRole() {
        let codex = SignIn(holder: .teamclaudeCodex, account: "someone@example.com",
                           failure: SignIn.Failure(code: "refresh_rejected", detail: "refused"))
        let (_, notices) = evaluate([codex], previous: AlertState())
        #expect(notices.map(\.title) == ["Codex in TeamClaude"])
        #expect(notices.first?.signIn == "teamclaudeCodex:someone@example.com")
    }

    @Test func aSignInThatIsGoneIsForgotten() {
        let (state, _) = evaluate([signIn(-60)], previous: AlertState())
        let (later, notices) = evaluate([], previous: state)
        #expect(notices.isEmpty)
        #expect(later.signIns == [:])
    }

    @Test func theStateRoundTripsAndReadsOlderFiles() throws {
        let (state, _) = evaluate([signIn(2 * hour)], previous: AlertState())
        let decoded = try JSONDecoder().decode(AlertState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        let older = Data(#"{"tiers": {}, "exhausted": false}"#.utf8)
        #expect(try JSONDecoder().decode(AlertState.self, from: older).signIns == nil)
    }
}

@Suite struct ReconnectTests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    func claude(_ account: String, expiresIn: TimeInterval?, failed: Bool = false) -> SignIn {
        SignIn(holder: .teamclaude, account: account, expiresAt: expiresIn.map(now.addingTimeInterval),
               failure: failed ? SignIn.Failure(code: "refresh_rejected", detail: "x") : nil)
    }

    @Test func aLaterExpiryOrAClearedRefusalIsARenewal() {
        let before = [claude("a", expiresIn: 18 * hour), claude("b", expiresIn: 9 * day)]
        let after = [claude("a", expiresIn: 30 * day), claude("b", expiresIn: 9 * day)]
        #expect(Reconnect.outcome(target: before[0], before: before, after: after, succeeded: true)
            == .renewed(until: now.addingTimeInterval(30 * day)))

        let refused = [claude("a", expiresIn: nil, failed: true)]
        #expect(Reconnect.outcome(target: refused[0], before: refused, after: [claude("a", expiresIn: nil)],
                                  succeeded: true) == .renewed(until: nil))
    }

    @Test func aRenewalOfAnotherAccountIsNamed() {
        let before = [claude("a", expiresIn: 18 * hour), claude("b", expiresIn: 9 * day)]
        let after = [claude("a", expiresIn: 18 * hour), claude("b", expiresIn: 30 * day)]
        #expect(Reconnect.outcome(target: before[0], before: before, after: after, succeeded: true)
            == .renewedOther(["b"]))
        // An account the browser was signed in to and TeamClaude did not have yet.
        let added = before + [claude("c", expiresIn: 30 * day)]
        #expect(Reconnect.outcome(target: before[0], before: before, after: added, succeeded: true)
            == .renewedOther(["c"]))
    }

    @Test func nothingChangedIsNoRenewalEvenWhenTheCommandSucceeded() {
        let before = [claude("a", expiresIn: 18 * hour)]
        #expect(Reconnect.outcome(target: before[0], before: before, after: before, succeeded: true) == .unchanged)
        #expect(Reconnect.outcome(target: before[0], before: before, after: before, succeeded: false) == .unchanged)
        // A refusal that is still there after the command.
        let refused = [claude("a", expiresIn: nil, failed: true)]
        #expect(Reconnect.outcome(target: refused[0], before: refused, after: refused, succeeded: true) == .unchanged)
    }

    @Test func aSignInWithoutADateTrustsTheCommand() {
        let codex = SignIn(holder: .codex, account: "openai")
        #expect(Reconnect.outcome(target: codex, before: [codex], after: [codex], succeeded: true)
            == .renewed(until: nil))
        #expect(Reconnect.outcome(target: codex, before: [codex], after: [codex], succeeded: false) == .unchanged)
        // The Codex login is read again only after the command, so it can be missing afterwards.
        #expect(Reconnect.outcome(target: codex, before: [codex], after: [], succeeded: true) == .renewed(until: nil))
    }

    @Test func theReasonOfAFailedLoginIsOneLine() {
        let output = """
        Starting OAuth login...
        Opening browser for authentication...
        If it doesn't open, visit:
          https://claude.example/oauth/authorize?code_challenge=abc&state=def

        OAuth login failed: Login timed out after 2 minutes

        Alternatives:
          teamclaude import        Import from existing Claude Code credentials
        """
        #expect(Reconnect.failureReason(output) == "Login timed out after 2 minutes")
        #expect(Reconnect.failureReason("Codex login failed: port 1455 is in use\n") == "port 1455 is in use")
        #expect(Reconnect.failureReason("Could not identify OAuth account — profile unavailable\nRetry later")
            == "Could not identify OAuth account — profile unavailable")
        #expect(Reconnect.failureReason("Opening browser...\n  https://x.example/?state=1\n") == nil)
    }
}

@Suite struct CodexSignInTests {
    @Test func aReadRefusedForTheLoginIsASignInFailure() throws {
        let signedOut = Codex.CodexError.requestFailed("codex account authentication required to read rate limits")
        #expect(Codex.signInFailure(signedOut)?.code == "signed_out")

        let expired = Codex.CodexError.requestFailed("failed to fetch codex rate limits: Your access token could not be "
            + "refreshed because your refresh token has expired. Please log out and sign in again.")
        let failure = try #require(Codex.signInFailure(expired))
        #expect(failure.code == "refresh_rejected")
        #expect(failure.detail == "Your access token could not be refreshed because your refresh token has expired")
        #expect(failure.fixedBySigningIn)
        // The read does not say when the login stopped working.
        #expect(failure.since == nil)
        #expect(SignIn(holder: .codex, account: "openai", failure: failure).explanation(now: Date())
            == "Your access token could not be refreshed because your refresh token has expired.")

        #expect(Codex.signInFailure(Codex.CodexError.requestFailed("failed to fetch codex rate limits: 401 Unauthorized"))?
            .code == "refresh_rejected")
    }

    @Test func otherFailuresAreNotAboutTheLogin() {
        #expect(Codex.signInFailure(Codex.CodexError.timedOut) == nil)
        #expect(Codex.signInFailure(Codex.CodexError.closed) == nil)
        #expect(Codex.signInFailure(Codex.CodexError.requestFailed("failed to fetch codex rate limits: no snapshots "
            + "returned")) == nil)
        // An API key login has no ChatGPT limits; signing in again would replace it.
        #expect(Codex.signInFailure(Codex.CodexError.requestFailed("chatgpt authentication required to read rate limits"))
            == nil)
    }
}

@Suite struct ProcessHandleTests {
    @Test func cancelStopsARunningCommand() async throws {
        let handle = ProcessHandle()
        let start = Date()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            handle.cancel()
        }
        let result = try await Shell.run("/bin/sleep", ["30"], timeout: 20, handle: handle)
        #expect(result.cancelled)
        #expect(!result.timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aCommandCancelledBeforeItStartsStopsAtOnce() async throws {
        let handle = ProcessHandle()
        handle.cancel()
        let start = Date()
        let result = try await Shell.run("/bin/sleep", ["30"], timeout: 20, handle: handle)
        #expect(result.cancelled)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aCommandThatEndsByItselfIsNotCancelled() async throws {
        let result = try await Shell.run("/bin/echo", ["hi"], handle: ProcessHandle())
        #expect(!result.cancelled)
        #expect(result.output == "hi\n")
    }
}
