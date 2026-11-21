import Foundation
import SQLite3

/// Google AI subscription quota through the Antigravity CLI (`agy -p "/usage" --output-format json`)
/// and read-only session metadata from Antigravity's local `conversation_summaries.db` stores.
/// The CLI holds the Google sign-in; this process never reads credentials or OAuth tokens.
///
/// Google groups the models of a subscription, and each group has a weekly and a 5-hour limit of
/// its own, so each group is one account here.
public enum GoogleAI {
    /// The row shown while no group could be read, and the prefix of every group's id.
    public static let key = "google"
    /// Seconds between reads. Each one is a request to Google, and the windows move slowly.
    public static let interval: TimeInterval = 300
    /// Window before an un-updated `CASCADE_RUN_STATUS_RUNNING` row is treated as a crashed session.
    public static let runningSessionTTL: TimeInterval = 15 * 60
    public static let activeSessionTTL: TimeInterval = 2 * 60
    public static let knownSessionTTL: TimeInterval = 60 * 60

    /// Live and recent top-level Antigravity sessions, read without touching credentials or message text.
    public struct SessionActivity: Sendable, Equatable {
        public var active: Int
        public var known: Int
        public var lastUsed: Date?

        public init(active: Int = 0, known: Int = 0, lastUsed: Date? = nil) {
            self.active = active
            self.known = known
            self.lastUsed = lastUsed
        }
    }

    /// True for the placeholder row and for any quota group's id, and false for an email such as `google@…`.
    public static func isKey(_ id: String) -> Bool { id == key || id.hasPrefix("\(key).") }

    static let arguments = ["-p", "/usage", "--output-format", "json", "--print-timeout", "20s"]

    public struct ReadError: LocalizedError, Equatable {
        public var message: String
        public var signedOut: Bool
        public init(_ message: String, signedOut: Bool = false) {
            self.message = message
            self.signedOut = signedOut
        }
        public var errorDescription: String? { message }
    }

    public enum SignInOutcome: Sendable, Equatable {
        case succeeded
        case cancelled
        case failed(String)
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> [AccountSnapshot] {
        guard let answer = try? JSONValue.parse(data), answer.object != nil else {
            throw ReadError(lastLine(String(decoding: data, as: UTF8.self)) ?? "No answer from the Antigravity CLI")
        }
        if let status = answer["status"]?.string, status != "SUCCESS" {
            throw ReadError(said(answer) ?? "The Antigravity CLI answered \(status)")
        }
        var accounts = groups(answer["command"]?["data"]?["groups"], now: now)
        // The tab-separated records are the documented output; the structured copy is read first for
        // the window lengths and the models it names.
        if accounts.isEmpty { accounts = records(answer["response"]?.string ?? "", now: now) }
        guard !accounts.isEmpty else { throw ReadError("No quota reported") }
        return accounts
    }

    private static func groups(_ value: JSONValue?, now: Date) -> [AccountSnapshot] {
        (value?.array ?? []).compactMap { group in
            guard let name = group["name"]?.string else { return nil }
            var covers = group["description"]?.string
            if let text = covers, let colon = text.range(of: ": ") { covers = String(text[colon.upperBound...]) }
            let windows = (group["buckets"]?.array ?? []).compactMap { bucket -> LimitWindow? in
                guard let left = bucket["remaining_fraction"]?.double else { return nil }
                let name = bucket["name"]?.string ?? bucket["id"]?.string ?? ""
                return window(kind: bucket["window"]?.string, name: name, left: left,
                              reset: bucket["reset_time"]?.string)
            }
            return account(name: name, covers: covers, windows: windows, now: now)
        }
    }

    /// One record per line: group, limit, percent left, reset time.
    private static func records(_ text: String, now: Date) -> [AccountSnapshot] {
        var order: [String] = [], windows: [String: [LimitWindow]] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, let left = Double(fields[2].replacingOccurrences(of: "%", with: "")) else { continue }
            if windows[fields[0]] == nil { order.append(fields[0]) }
            windows[fields[0], default: []].append(window(kind: nil, name: fields[1], left: left / 100,
                                                          reset: fields.count > 3 ? fields[3] : nil))
        }
        return order.compactMap { account(name: $0, covers: nil, windows: windows[$0] ?? [], now: now) }
    }

    private static func account(name: String, covers: String?, windows: [LimitWindow], now: Date) -> AccountSnapshot? {
        guard !windows.isEmpty else { return nil }
        var title = name.trimmingCharacters(in: .whitespaces)
        if title.lowercased().hasSuffix(" models") { title = String(title.dropLast(7)) }
        var snapshot = AccountSnapshot(id: "\(key).\(slug(title))", provider: .google)
        snapshot.title = title
        snapshot.covers = covers
        // Short windows first, as for Claude.
        snapshot.windows = windows.sorted { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }
        snapshot.fetchedAt = now
        snapshot.staleAfter = interval * 2 + 60
        snapshot.signIn = SignIn(holder: .google, account: key)
        return snapshot
    }

    private static func window(kind: String?, name: String, left: Double, reset: String?) -> LimitWindow {
        let lowered = name.lowercased()
        var label = name
        if lowered.hasSuffix(" remaining") { label = String(name.dropLast(10)) }
        let (id, title, duration): (String, String, TimeInterval?)
        if kind == "weekly" || (kind == nil && lowered.contains("weekly")) {
            (id, title, duration) = ("7d", "Weekly", 7 * 86_400)
        } else if kind == "5h" || (kind == nil && lowered.contains("five hour")) {
            (id, title, duration) = ("5h", "5-hour", 5 * 3600)
        } else {
            (id, title, duration) = (kind ?? slug(label), label, nil)
        }
        let used = min(100, max(0, ((1 - left) * 1000).rounded() / 10))
        // Until its first request a window ends a whole window from now, at every read: nothing counts down.
        let resetsAt = left < 1 ? reset.flatMap(date) : nil
        return LimitWindow(id: id, title: title, used: used, resetsAt: resetsAt, duration: duration)
    }

    private static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func summaryDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = trimmed.firstIndex(of: " ").map { space in
            String(trimmed[..<space]) + "T" + String(trimmed[trimmed.index(after: space)...])
        } ?? trimmed
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: iso) {
            return parsed.timeIntervalSince1970 > 0 ? parsed : nil
        }
        let plain = ISO8601DateFormatter()
        guard let parsed = plain.date(from: iso), parsed.timeIntervalSince1970 > 0 else { return nil }
        return parsed
    }

    /// Candidate `conversation_summaries.db` files holding local Antigravity / Gemini sessions.
    public static func sessionDatabases(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        let manager = FileManager.default
        var candidates = [
            "\(home)/.gemini/antigravity-cli/conversation_summaries.db",
            "\(home)/.gemini/antigravity/conversation_summaries.db",
        ]
        let t3Root = "\(home)/.t3/userdata/providers/antigravity"
        if let entries = try? manager.contentsOfDirectory(atPath: t3Root) {
            for entry in entries {
                candidates.append("\(t3Root)/\(entry)/antigravity-acp/conversation_summaries.db")
            }
        }
        var seen: Set<String> = []
        return candidates.filter { path in
            seen.insert(path).inserted && manager.isReadableFile(atPath: path)
        }.sorted()
    }

    private struct SessionRecord {
        var modified: Date
        var running: Bool
    }

    /// Read live and recent top-level Antigravity sessions from local `conversation_summaries.db` files.
    /// Credentials, OAuth tokens, titles and message contents are never read.
    public static func readSessions(databases: [String]? = nil, now: Date = Date()) -> SessionActivity {
        let paths = databases ?? sessionDatabases()
        var byID: [String: SessionRecord] = [:]
        let sql = """
            SELECT conversation_id, status, not_fully_idle, last_modified_time
            FROM conversation_summaries
            WHERE killed = 0 AND parent_conversation_id = ''
            """
        for path in paths {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 200)

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                continue
            }
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(statement, 0),
                      let timePtr = sqlite3_column_text(statement, 3),
                      let modified = summaryDate(String(cString: timePtr)) else { continue }
                let id = String(cString: idPtr)
                let status = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                let notFullyIdle = sqlite3_column_int(statement, 2) != 0
                let running = status == "CASCADE_RUN_STATUS_RUNNING" || notFullyIdle
                if let existing = byID[id] {
                    if modified > existing.modified {
                        byID[id] = SessionRecord(modified: modified, running: running)
                    } else if modified == existing.modified {
                        byID[id] = SessionRecord(modified: modified, running: existing.running || running)
                    }
                } else {
                    byID[id] = SessionRecord(modified: modified, running: running)
                }
            }
        }

        var active = 0
        var known = 0
        var lastUsed: Date?
        for record in byID.values {
            let age = now.timeIntervalSince(record.modified)
            guard age >= -60 else { continue }
            let capped = min(now, record.modified)
            if lastUsed.map({ capped > $0 }) ?? true { lastUsed = capped }
            let isActive = (record.running && age <= runningSessionTTL) || age <= activeSessionTTL
            if isActive { active += 1 }
            if isActive || age <= knownSessionTTL { known += 1 }
        }
        return SessionActivity(active: active, known: known, lastUsed: lastUsed)
    }

    /// Attaches Google AI session activity to one active quota group so totals are never double-counted.
    public static func apply(_ activity: SessionActivity, to accounts: [AccountSnapshot]) -> [AccountSnapshot] {
        var result = accounts
        for index in result.indices where result[index].provider == .google {
            result[index].sessions = 0
            result[index].knownSessions = 0
            result[index].lastUsed = nil
        }
        let candidates = result.indices.filter { result[$0].provider == .google && !result[$0].windows.isEmpty }
        guard !candidates.isEmpty else { return result }

        func preferred(_ indices: [Int]) -> Int {
            indices.first { result[$0].id == "\(key).gemini" } ?? indices[0]
        }

        let target: Int
        let active5h = candidates.filter { (result[$0].window("5h")?.used ?? 0) > 0 }
        if !active5h.isEmpty {
            let top = active5h.compactMap { result[$0].window("5h")?.used }.max() ?? 0
            target = preferred(active5h.filter { (result[$0].window("5h")?.used ?? 0) == top })
        } else {
            let withUsage = candidates.filter { (result[$0].peak ?? 0) > 0 }
            if !withUsage.isEmpty {
                let top = withUsage.compactMap { result[$0].peak }.max() ?? 0
                target = preferred(withUsage.filter { (result[$0].peak ?? 0) == top })
            } else {
                target = preferred(candidates)
            }
        }
        result[target].sessions = activity.active
        result[target].knownSessions = activity.known
        result[target].lastUsed = activity.lastUsed
        return result
    }

    static func slug(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }

    private static func lastLine(_ text: String) -> String? {
        let line = text.split(separator: "\n").last {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            // OAuth links carry one-time state and have no place in a status line.
            return !trimmed.isEmpty && !trimmed.contains("://")
        }
        return line.map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }
    }

    /// What a refusing answer says, in the CLI's words.
    private static func said(_ answer: JSONValue) -> String? {
        let text = answer["error"]?.string ?? answer["error"]?["message"]?.string ?? answer["response"]?.string
        return text.flatMap(lastLine)
    }

    private static func needsSignIn(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("authentication required") || lowered.contains("authentication failed")
    }

    /// Why a run gave no answer to parse, or nil when it did.
    public static func failure(_ result: ProcessResult) -> ReadError? {
        guard result.timedOut || result.status != 0 else { return nil }
        if needsSignIn(result.errorOutput) || needsSignIn(result.output) {
            return ReadError("The Antigravity CLI is not signed in", signedOut: true)
        }
        if result.timedOut { return ReadError("The Antigravity CLI timed out") }
        if let answer = try? JSONValue.parse(result.stdout), let text = said(answer) { return ReadError(text) }
        return ReadError(lastLine(result.errorOutput) ?? lastLine(result.output)
            ?? "The Antigravity CLI exited with status \(result.status)")
    }

    /// What a failed read says about the Google login, or nil when the failure is about something else.
    public static func signInFailure(_ error: Error) -> SignIn.Failure? {
        guard let readError = error as? ReadError else { return nil }
        if readError.signedOut {
            return SignIn.Failure(code: "signed_out", detail: "The Antigravity CLI is not signed in")
        }
        let text = readError.message.lowercased()
        if text.contains("not signed in") || text.contains("authentication required")
            || text.contains("authentication failed") {
            return SignIn.Failure(code: "signed_out", detail: "The Antigravity CLI is not signed in")
        }
        let refused = ["sign in again", "unauthorized", "could not be refreshed", "invalid_grant"]
            .contains(where: text.contains)
        return refused ? SignIn.Failure(code: "refresh_rejected", detail: readError.message) : nil
    }

    /// True when the failure says the CLI uses a `GEMINI_API_KEY` (which has no account quota).
    public static func isAPIKeyOnly(_ error: Error) -> Bool {
        (error as? ReadError)?.message.lowercased().contains("api key") == true
    }

    /// The rows after a read. A failed read keeps the last readings on screen, marked with the error;
    /// without any, one row says why there is nothing to show (unless the CLI is using an API key).
    public static func merge(_ read: Result<[AccountSnapshot], Error>, last: [AccountSnapshot]) -> [AccountSnapshot] {
        switch read {
        case .success(let accounts):
            return accounts
        case .failure(let error):
            let kept = last.filter { !$0.windows.isEmpty }
            if kept.isEmpty, isAPIKeyOnly(error) { return [] }
            let signIn = signInFailure(error).map { SignIn(holder: .google, account: key, failure: $0) }
            if kept.isEmpty {
                var row = AccountSnapshot.unavailable(key, provider: .google, error: error.localizedDescription)
                row.signIn = signIn
                return [row]
            }
            return kept.map {
                var account = $0
                account.error = error.localizedDescription
                if let signIn { account.signIn = signIn }
                return account
            }
        }
    }

    /// Candidate locations when the config does not name one.
    public static func locate(configured: String?) -> String? {
        if let configured {
            return configured.isEmpty ? nil : AppConfig.expand(configured)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Environment for `agy`: strips SSH and IDE-harness overrides that force `agy` off macOS Keychain
    /// and onto manual copy-paste OAuth, and turns off background auto-updates.
    static func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        for key in ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY", "AGY_ACP_FORCE_FILE_STORAGE",
                    "ANTIGRAVITY_APP_DATA_DIR", "BROWSER"] {
            env.removeValue(forKey: key)
        }
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        return env
    }

    /// Ask the CLI for the quota of the account it is signed in to. A read-only command: no model runs.
    public static func fetchUsage(agy: String, environment: [String: String],
                                  timeout: TimeInterval = 25) async throws -> Data {
        let result = try await Shell.run(agy, arguments, environment: Self.environment(environment), timeout: timeout,
                                         stopOnStderr: { needsSignIn($0) })
        if let failure = failure(result) { throw failure }
        return result.stdout
    }

    /// Sign in with Google through `agy acp --stdio` (`initialize`, then `authenticate` with
    /// `oauth-personal`), which opens the default browser with a localhost callback so no code has to
    /// be copied back. Stops the server once the sign-in finishes or is cancelled.
    public static func signIn(agy: String, environment: [String: String], timeout: TimeInterval = 300,
                              handle: ProcessHandle? = nil) async -> SignInOutcome {
        let env = Self.environment(environment)
        return (try? await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).async {
                once.resume(.success(signInBlocking(agy: agy, environment: env, timeout: timeout, handle: handle)))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + Shell.killGrace + 2) {
                once.resume(.success(.failed("no sign-in arrived in time")))
            }
        }) ?? .failed("the sign-in could not be started")
    }

    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }

    private static func signInBlocking(agy: String, environment: [String: String], timeout: TimeInterval,
                                       handle: ProcessHandle?) -> SignInOutcome {
        if handle?.cancelled == true { return .cancelled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: agy)
        process.arguments = ["acp", "--stdio"]
        process.environment = environment
        let input = Pipe(), output = Pipe(), errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return .failed("the Antigravity CLI could not be started: \(error.localizedDescription)")
        }
        handle?.attach(process)

        let errData = DataBox()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global().async {
            errData.value = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }

        let lock = NSLock()
        var timedOut = false
        let watchdog = DispatchWorkItem {
            lock.lock(); timedOut = true; lock.unlock()
            Shell.stop(process)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            Shell.stop(process)
            process.waitUntilExit()
            _ = errGroup.wait(timeout: .now() + 1)
        }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        var buffer = Data()
        func receive(_ id: Int) -> SignInOutcome? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (message["id"] as? Int) == id else { continue }
                    if handle?.cancelled == true { return .cancelled }
                    if let error = message["error"] {
                        let text = (error as? [String: Any])?["message"] as? String ?? "\(error)"
                        return .failed(text)
                    }
                    return nil
                }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty {
                    if handle?.cancelled == true { return .cancelled }
                    lock.lock(); let expired = timedOut; lock.unlock()
                    if expired { return .failed("no sign-in arrived in time") }
                    Shell.stop(process)
                    process.waitUntilExit()
                    _ = errGroup.wait(timeout: .now() + 1)
                    if let reason = lastLine(String(decoding: errData.value, as: UTF8.self)) {
                        return .failed(reason)
                    }
                    return .failed("the Antigravity CLI closed before sign-in finished")
                }
                buffer.append(chunk)
            }
        }

        do {
            try send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": ["protocolVersion": 1, "clientCapabilities": [String: Any]()]])
            if let failure = receive(1) { return failure }
            try send(["jsonrpc": "2.0", "id": 2, "method": "authenticate",
                      "params": ["methodId": "oauth-personal"]])
            if let failure = receive(2) { return failure }
            return .succeeded
        } catch {
            if handle?.cancelled == true { return .cancelled }
            return .failed(error.localizedDescription)
        }
    }
}
