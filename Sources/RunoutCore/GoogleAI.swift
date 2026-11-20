import Foundation

/// Google AI subscription quota through the Antigravity CLI: `agy -p "/usage" --output-format json`.
/// The CLI holds the Google sign-in; this process never sees a credential and reads none of its files.
///
/// Google groups the models of a subscription, and each group has a weekly and a 5-hour limit of
/// its own, so each group is one account here.
public enum GoogleAI {
    /// The row shown while no group could be read, and the prefix of every group's id.
    public static let key = "google"
    /// Seconds between reads. Each one is a request to Google, and the windows move slowly.
    public static let interval: TimeInterval = 300

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
