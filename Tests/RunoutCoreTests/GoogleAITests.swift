import Foundation
import SQLite3
import Testing
@testable import RunoutCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

/// The fixture is noon on 1 December 2026 for the reader: both untouched windows of the second group
/// end one whole window later.
private let now = Date(timeIntervalSince1970: 1_796_126_400)

@Suite struct GoogleAITests {
    @Test func readsOneAccountPerQuotaGroup() throws {
        let accounts = try GoogleAI.parse(try fixture("agy-usage"), now: now)
        #expect(accounts.map(\.id) == ["google.gemini", "google.claude-and-gpt"])
        #expect(accounts.allSatisfy { $0.provider == .google && $0.fetchedAt == now && $0.error == nil })
        #expect(accounts.allSatisfy { $0.signIn == SignIn(holder: .google, account: GoogleAI.key) })

        let gemini = try #require(accounts.first)
        #expect(gemini.title == "Gemini")
        #expect(gemini.covers == "Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Argon")
        // Short windows first, with the ids the rows and the history share with Claude and Codex.
        #expect(gemini.windows.map(\.id) == ["5h", "7d"])
        #expect(gemini.windows.map(\.title) == ["5-hour", "Weekly"])
        // The CLI reports what is left; the app shows what is used.
        #expect(gemini.window("7d")?.used == 37)
        #expect(gemini.window("5h")?.used == 80)
        #expect(gemini.window("7d")?.resetsAt == date("2026-12-04T09:30:00Z"))
        #expect(gemini.window("5h")?.resetsAt == date("2026-12-01T14:10:00Z"))
        #expect(gemini.weekly?.isWeekly == true)
        #expect(gemini.window("5h")?.duration == TimeInterval(5 * 3600))
        // Read less often than the proxy, so a reading stays fresh across a missed read.
        #expect(!gemini.isStale(at: now.addingTimeInterval(GoogleAI.interval * 2)))
        #expect(gemini.isStale(at: now.addingTimeInterval(GoogleAI.interval * 2 + 120)))
    }

    @Test func anUntouchedWindowHasNoCountdown() throws {
        // Until its first request a window ends a whole window from now, at every read: nothing counts down.
        let pool = try #require(try GoogleAI.parse(try fixture("agy-usage"), now: now).last)
        #expect(pool.title == "Claude and GPT")
        #expect(pool.windows.map(\.used) == [0, 0])
        #expect(pool.windows.map(\.resetsAt) == [nil, nil])
        #expect(pool.peak == 0)

        // Even a tiny amount used starts the countdown, though the percent rounds to 0.0.
        let started = """
        {"status": "SUCCESS", "command": {"name": "usage", "data": {"groups": [{"name": "Gemini Models", "buckets": [
          {"id": "gemini-weekly", "name": "Weekly Limit Remaining", "window": "weekly",
           "remaining_fraction": 0.9998, "reset_time": "2026-12-08T11:55:00Z"}]}]}}}
        """
        let window = try #require(try GoogleAI.parse(Data(started.utf8), now: now).first?.window("7d"))
        #expect(window.used == 0)
        #expect(window.resetsAt == date("2026-12-08T11:55:00Z"))
    }

    @Test func fallsBackToTheTabSeparatedRecords() throws {
        // The records are the documented output; the structured copy beside them may not always be there.
        let records = "Gemini Models\tWeekly Limit Remaining\t63%\t2026-12-04T09:30:00Z\n"
            + "Gemini Models\tFive Hour Limit Remaining\t20%\t2026-12-01T14:10:00Z\n"
            + "Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-12-08T12:00:00Z\n"
        let body = try JSONSerialization.data(withJSONObject: ["status": "SUCCESS", "response": records])
        let accounts = try GoogleAI.parse(body, now: now)
        #expect(accounts.map(\.id) == ["google.gemini", "google.claude-and-gpt"])
        #expect(accounts[0].windows.map(\.id) == ["5h", "7d"])
        #expect(accounts[0].window("7d")?.used == 37)
        #expect(accounts[0].window("5h")?.resetsAt == date("2026-12-01T14:10:00Z"))
        #expect(accounts[0].covers == nil)
        #expect(accounts[1].windows.map(\.id) == ["7d"])
        #expect(accounts[1].window("7d")?.resetsAt == nil)
    }

    @Test func keepsAWindowItDoesNotKnow() throws {
        let json = """
        {"status": "SUCCESS", "command": {"name": "usage", "data": {"groups": [{"name": "Gemini Models", "buckets": [
          {"id": "gemini-daily", "name": "Daily Limit Remaining", "window": "daily", "remaining_fraction": 0.5,
           "reset_time": "2026-12-02T00:00:00Z"}]}]}}}
        """
        let window = try #require(try GoogleAI.parse(Data(json.utf8), now: now).first?.windows.first)
        #expect(window.id == "daily")
        #expect(window.title == "Daily Limit")
        #expect(window.used == 50)
        #expect(window.duration == nil)
    }

    @Test func anAnswerWithoutQuotaIsAnError() throws {
        // An API key has no account quota; the CLI says so instead of listing groups.
        let refused = #"{"status": "ERROR", "error": "Quota is not available with an API key"}"#
        #expect { try GoogleAI.parse(Data(refused.utf8), now: now) } throws: { error in
            error.localizedDescription.contains("Quota is not available with an API key")
        }
        #expect(throws: GoogleAI.ReadError.self) { try GoogleAI.parse(Data(#"{"status": "SUCCESS"}"#.utf8), now: now) }
        #expect(throws: (any Error).self) { try GoogleAI.parse(Data("Signed out".utf8), now: now) }
    }

    @Test func aFailedReadKeepsTheCLIsLastWords() {
        let failed = ProcessResult(status: 2, stdout: Data(), stderr: Data("warming up\nNot signed in. Run agy.\n".utf8),
                                   timedOut: false)
        #expect(GoogleAI.failure(failed)?.localizedDescription == "Not signed in. Run agy.")
        // A signed-out CLI waits for a browser login and hits the timeout: keep the sign-in message, never the URL.
        let authPrompt = "Authentication required. Please visit the URL to log in:\n"
            + "  https://accounts.google.com/o/oauth2/auth?state=secret\nWaiting for authentication (timeout 60s)...\n"
        let signedOut = ProcessResult(status: 1, stdout: Data(), stderr: Data(authPrompt.utf8), timedOut: true)
        let readError = GoogleAI.failure(signedOut)
        #expect(readError?.localizedDescription == "The Antigravity CLI is not signed in")
        #expect(readError?.signedOut == true)
        #expect(!(readError?.localizedDescription.contains("https://") ?? true))
        // An error whose last line is a link keeps the text above it instead of the link.
        let withLink = ProcessResult(status: 1, stdout: Data(),
                                     stderr: Data("Quota unavailable\nhttps://example.com/help\n".utf8), timedOut: false)
        #expect(GoogleAI.failure(withLink)?.localizedDescription == "Quota unavailable")
        let slow = ProcessResult(status: -1, stdout: Data(), stderr: Data(), timedOut: true)
        #expect(GoogleAI.failure(slow)?.localizedDescription == "The Antigravity CLI timed out")
        #expect(GoogleAI.failure(ProcessResult(status: 0, stdout: Data("{}".utf8), stderr: Data(), timedOut: false)) == nil)
    }

    @Test func keysMatchOnlyGoogleRows() {
        #expect(GoogleAI.isKey("google"))
        #expect(GoogleAI.isKey("google.gemini"))
        #expect(GoogleAI.isKey("google.claude-and-gpt"))
        #expect(!GoogleAI.isKey("google@example.com"))
        #expect(!GoogleAI.isKey("openai"))
    }

    @Test func stripsSSHandHarnessOverridesFromEnvironment() {
        let env = GoogleAI.environment([
            "HOME": "/Users/ada",
            "PATH": "/usr/bin:/bin",
            "SSH_CONNECTION": "10.0.0.1 1234 10.0.0.2 22",
            "SSH_CLIENT": "10.0.0.1 1234 22",
            "SSH_TTY": "/dev/ttys001",
            "AGY_ACP_FORCE_FILE_STORAGE": "1",
            "ANTIGRAVITY_APP_DATA_DIR": "/tmp/harness",
            "BROWSER": "/bin/false",
        ])
        #expect(env["HOME"] == "/Users/ada")
        #expect(env["AGY_CLI_DISABLE_AUTO_UPDATE"] == "1")
        for key in ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY", "AGY_ACP_FORCE_FILE_STORAGE",
                    "ANTIGRAVITY_APP_DATA_DIR", "BROWSER"] {
            #expect(env[key] == nil)
        }
    }

    @Test func classifiesSignInFailuresWithoutMisreadingAPIKeyErrors() {
        #expect(GoogleAI.signInFailure(GoogleAI.ReadError("The Antigravity CLI is not signed in", signedOut: true))?.code
            == "signed_out")
        #expect(GoogleAI.signInFailure(GoogleAI.ReadError("Not signed in"))?.code == "signed_out")
        #expect(GoogleAI.signInFailure(GoogleAI.ReadError("401 Unauthorized"))?.code == "refresh_rejected")
        #expect(GoogleAI.signInFailure(GoogleAI.ReadError("Quota is not available with an API key")) == nil)
        #expect(GoogleAI.signInFailure(GoogleAI.ReadError("The Antigravity CLI timed out")) == nil)
    }

    @Test func theConfigNamesOrHidesTheCLI() throws {
        #expect(GoogleAI.locate(configured: "") == nil)
        #expect(GoogleAI.locate(configured: "/opt/tools/agy") == "/opt/tools/agy")
        let hidden = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"agy": ""}"#.utf8))
        #expect(hidden.agy == "")
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8)).agy == nil)
    }

    @Test func aGroupIsNamedAfterWhatItCovers() {
        let config = AppConfig()
        let gemini = config.identity(for: "google.gemini", provider: .google, index: 4, title: "Gemini")
        #expect(gemini.label == "Gemini")
        #expect(gemini.letter == "G")
        #expect(gemini.symbol == "sparkle")
        // Before the first reading there is no group to name.
        #expect(config.identity(for: GoogleAI.key, provider: .google, index: 0).label == "Google AI")
        // A style in the config still wins.
        var styled = AppConfig()
        styled.accounts["google.gemini"] = AccountStyle(label: "Ultra")
        #expect(styled.identity(for: "google.gemini", provider: .google, index: 0, title: "Gemini").label == "Ultra")
    }
}

@Suite struct GoogleAIMergeTests {
    @Test func aFailedReadKeepsTheLastReadingsMarkedWithTheError() throws {
        let last = try GoogleAI.parse(try fixture("agy-usage"), now: now)
        let rows = GoogleAI.merge(.failure(GoogleAI.ReadError("Not signed in")), last: last)
        #expect(rows.map(\.id) == last.map(\.id))
        #expect(rows.allSatisfy { $0.error == "Not signed in" && $0.isStale(at: now) })
        #expect(rows.first?.window("7d")?.used == 37)
        // The next good read replaces them, error and all.
        #expect(GoogleAI.merge(.success(last), last: rows).allSatisfy { $0.error == nil })
    }

    @Test func aFirstFailedReadShowsOneRowThatSaysWhy() {
        let rows = GoogleAI.merge(.failure(GoogleAI.ReadError("Not signed in", signedOut: true)), last: [])
        #expect(rows.map(\.id) == [GoogleAI.key])
        #expect(rows.first?.provider == .google)
        #expect(rows.first?.error == "Not signed in")
        #expect(rows.first?.signIn?.holder == .google)
        #expect(rows.first?.signIn?.failure?.code == "signed_out")
        // That row is no reading to keep: a later failure still shows one row, and a non-auth error carries no signIn.
        let timedOut = GoogleAI.merge(.failure(GoogleAI.ReadError("Timed out")), last: rows)
        #expect(timedOut.map(\.error) == ["Timed out"])
        #expect(timedOut.first?.signIn == nil)
    }

    @Test func hidesGoogleRowsWhenOnlyAnAPIKeyIsSet() {
        let error = GoogleAI.ReadError("Quota is not available with an API key")
        #expect(GoogleAI.isAPIKeyOnly(error))
        #expect(!GoogleAI.isAPIKeyOnly(GoogleAI.ReadError("The Antigravity CLI timed out")))
        #expect(GoogleAI.merge(.failure(error), last: []).isEmpty)
    }
}

@Suite struct GoogleAISessionTests {
    private func createSummariesDB(at url: URL, rows: [(id: String, status: String, notIdle: Int, killed: Int,
                                                         parent: String, modified: String)]) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        guard let db else { return }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE conversation_summaries (
            conversation_id text PRIMARY KEY,
            status text NOT NULL DEFAULT "",
            not_fully_idle numeric NOT NULL DEFAULT false,
            killed numeric NOT NULL DEFAULT false,
            parent_conversation_id text NOT NULL DEFAULT "",
            last_modified_time datetime NOT NULL
        );
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        let sql = """
        INSERT INTO conversation_summaries
            (conversation_id, status, not_fully_idle, killed, parent_conversation_id, last_modified_time)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, row.id, -1, transient)
            sqlite3_bind_text(stmt, 2, row.status, -1, transient)
            sqlite3_bind_int(stmt, 3, Int32(row.notIdle))
            sqlite3_bind_int(stmt, 4, Int32(row.killed))
            sqlite3_bind_text(stmt, 5, row.parent, -1, transient)
            sqlite3_bind_text(stmt, 6, row.modified, -1, transient)
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    private func dbTime(_ date: Date, fractional: Bool = true) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: "T", with: " ")
    }

    @Test func readsActiveAndKnownSessionsFromConversationDatabases() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_795_266_600)  // 2026-11-21T13:10:00Z
        let db1 = dir.appendingPathComponent("one.db")
        let db2 = dir.appendingPathComponent("two.db")
        let corrupt = dir.appendingPathComponent("corrupt.db")
        try Data("not a sqlite file".utf8).write(to: corrupt)

        try createSummariesDB(at: db1, rows: [
            ("c1", "CASCADE_RUN_STATUS_RUNNING", 1, 0, "", dbTime(now.addingTimeInterval(-360))),
            ("c2", "CASCADE_RUN_STATUS_IDLE", 0, 0, "", dbTime(now.addingTimeInterval(-30), fractional: false)),
            ("c3", "CASCADE_RUN_STATUS_IDLE", 0, 0, "", dbTime(now.addingTimeInterval(-1200))),
            ("c4", "CASCADE_RUN_STATUS_RUNNING", 1, 0, "", dbTime(now.addingTimeInterval(-1500))),
            ("c5", "CASCADE_RUN_STATUS_RUNNING", 1, 1, "", dbTime(now.addingTimeInterval(-10))),
            ("c6", "CASCADE_RUN_STATUS_RUNNING", 1, 0, "c1", dbTime(now.addingTimeInterval(-10))),
            ("c7", "CASCADE_RUN_STATUS_IDLE", 0, 0, "", "0001-01-01 00:00:00+00:00"),
            ("c8", "CASCADE_RUN_STATUS_IDLE", 0, 0, "", dbTime(now.addingTimeInterval(-7200))),
        ])
        try createSummariesDB(at: db2, rows: [
            ("c1", "CASCADE_RUN_STATUS_IDLE", 0, 0, "", dbTime(now.addingTimeInterval(-900))),
            ("c9", "CASCADE_RUN_STATUS_IDLE", 0, 0, "", dbTime(now.addingTimeInterval(-2700))),
        ])

        let activity = GoogleAI.readSessions(databases: [db1.path, db2.path, corrupt.path,
                                                         dir.appendingPathComponent("missing.db").path], now: now)
        #expect(activity.active == 2)
        #expect(activity.known == 5)
        #expect(activity.lastUsed == now.addingTimeInterval(-30))
    }

    @Test func discoversSessionDatabasesUnderStandardRoots() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cliDB = home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")
        let t3DB = home.appendingPathComponent(".t3/userdata/providers/antigravity/hash1/antigravity-acp/conversation_summaries.db")
        for url in [cliDB, t3DB] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        #expect(GoogleAI.sessionDatabases(home: home.path) == [cliDB.path, t3DB.path].sorted())
    }

    @Test func appliesSessionsToASingleActiveGoogleGroup() throws {
        var accounts = try GoogleAI.parse(try fixture("agy-usage"), now: now)
        accounts[1].sessions = 9
        accounts[1].knownSessions = 12
        let activity = GoogleAI.SessionActivity(active: 2, known: 5, lastUsed: now.addingTimeInterval(-45))

        let applied = GoogleAI.apply(activity, to: accounts)
        #expect(applied[0].sessions == 2)
        #expect(applied[0].knownSessions == 5)
        #expect(applied[0].lastUsed == activity.lastUsed)
        #expect(applied[1].sessions == 0)
        #expect(applied[1].knownSessions == 0)
        #expect(applied[1].lastUsed == nil)

        // When only Claude and GPT has active 5-hour usage, it receives the session attribution instead.
        var thirdPartyActive = accounts
        thirdPartyActive[0].windows[0].used = 10
        thirdPartyActive[1].windows[0].used = 40
        let switched = GoogleAI.apply(activity, to: thirdPartyActive)
        #expect(switched[0].sessions == 0)
        #expect(switched[1].sessions == 2)
        #expect(switched[1].knownSessions == 5)

        // A placeholder signed-out row without windows holds no quota groups to attach to.
        var placeholder = [AccountSnapshot.unavailable(GoogleAI.key, provider: .google, error: "Not signed in")]
        placeholder[0].sessions = 3
        let cleared = GoogleAI.apply(activity, to: placeholder)
        #expect(cleared[0].sessions == 0)
        #expect(cleared[0].knownSessions == 0)
        #expect(cleared[0].lastUsed == nil)
    }
}

/// The usage read against a stand-in `agy`: a shell script that logs its arguments and env and answers
/// with recorded JSON or an error. No real Google login is touched.
@Suite struct GoogleAIFetchTests {
    func fakeCLI(_ body: String) throws -> (path: String, dir: URL, log: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("agy")
        let log = dir.appendingPathComponent("call.log")
        let content = """
        #!/bin/sh
        printf '%s\\n' "$AGY_CLI_DISABLE_AUTO_UPDATE" > "$CALL_LOG"
        printf '%s\\n' "$@" >> "$CALL_LOG"
        \(body)
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, dir, log)
    }

    @Test func passesReadOnlyArgsAndDisablesAutoUpdate() async throws {
        let fixtureURL = try #require(Bundle.module.url(forResource: "agy-usage", withExtension: "json",
                                                        subdirectory: "Fixtures"))
        let cli = try fakeCLI("cat \"\(fixtureURL.path)\"")
        defer { try? FileManager.default.removeItem(at: cli.dir) }
        let data = try await GoogleAI.fetchUsage(agy: cli.path, environment: ["PATH": "/usr/bin:/bin",
                                                                              "CALL_LOG": cli.log.path], timeout: 10)
        let accounts = try GoogleAI.parse(data, now: now)
        #expect(accounts.map(\.id) == ["google.gemini", "google.claude-and-gpt"])
        let logged = try String(contentsOf: cli.log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(logged.first == "1")
        #expect(Array(logged.dropFirst()) == GoogleAI.arguments)
    }

    @Test func turnsASignedOutWaitIntoASignInError() async throws {
        let cli = try fakeCLI("""
        printf 'Authentication required. Please visit the URL to log in:\\n  https://accounts.google.com/o/oauth2/auth\\n' >&2
        sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: cli.dir) }
        let start = Date()
        await #expect {
            _ = try await GoogleAI.fetchUsage(agy: cli.path, environment: ["PATH": "/usr/bin:/bin",
                                                                           "CALL_LOG": cli.log.path], timeout: 20)
        } throws: { error in
            GoogleAI.signInFailure(error)?.code == "signed_out"
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    /// Stand-in `agy acp --stdio` server that logs incoming JSON-RPC lines and answers `authenticate`.
    func fakeACP(authReply: String) throws -> (path: String, dir: URL, log: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("agy")
        let log = dir.appendingPathComponent("acp.log")
        let content = """
        #!/bin/sh
        printf 'ENV_SSH=%s\\n' "$SSH_CONNECTION" > "$ACP_LOG"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$ACP_LOG"
          case "$line" in
            *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}' ;;
            *'"method":"authenticate"'*) \(authReply) ;;
          esac
        done
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, dir, log)
    }

    @Test func browserSignInRunsACPAuthenticateWithoutSSHVars() async throws {
        let server = try fakeACP(authReply: #"echo '{"jsonrpc":"2.0","id":2,"result":{}}'"#)
        defer { try? FileManager.default.removeItem(at: server.dir) }
        let outcome = await GoogleAI.signIn(agy: server.path, environment: [
            "PATH": "/usr/bin:/bin", "ACP_LOG": server.log.path, "SSH_CONNECTION": "1.2.3.4 1 2 22",
        ], timeout: 10)
        #expect(outcome == .succeeded)
        let lines = try String(contentsOf: server.log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.first == "ENV_SSH=")
        let auth = try JSONValue.parse(Data((lines.last ?? "").utf8))
        #expect(auth["method"]?.string == "authenticate")
        #expect(auth["params"]?["methodId"]?.string == "oauth-personal")
    }

    @Test func browserSignInReportsFailureAndSupportsCancel() async throws {
        let failing = try fakeACP(authReply: #"echo '{"jsonrpc":"2.0","id":2,"error":{"code":-32800,"message":"Sign-in was cancelled."}}'"#)
        defer { try? FileManager.default.removeItem(at: failing.dir) }
        let failed = await GoogleAI.signIn(agy: failing.path, environment: ["PATH": "/usr/bin:/bin",
                                                                            "ACP_LOG": failing.log.path], timeout: 10)
        #expect(failed == .failed("Sign-in was cancelled."))

        let waiting = try fakeACP(authReply: "sleep 30")
        defer { try? FileManager.default.removeItem(at: waiting.dir) }
        let handle = ProcessHandle()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            handle.cancel()
        }
        let start = Date()
        let cancelled = await GoogleAI.signIn(agy: waiting.path, environment: ["PATH": "/usr/bin:/bin",
                                                                               "ACP_LOG": waiting.log.path],
                                              timeout: 20, handle: handle)
        #expect(cancelled == .cancelled)
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test func browserSignInSurfacesStderrOnEarlyExit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("agy")
        try "#!/bin/sh\necho 'keychain access denied' >&2\nexit 1\n".write(to: script, atomically: true,
                                                                           encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let outcome = await GoogleAI.signIn(agy: script.path, environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        #expect(outcome == .failed("keychain access denied"))
    }
}
