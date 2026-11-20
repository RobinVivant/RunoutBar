import AppKit
import Foundation
import os
import Observation
import RunoutCore

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case bars, barsAndPercent, letters
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: return "Level bars"
        case .barsAndPercent: return "Level bars and percent"
        case .letters: return "Letters and numbers"
        }
    }
}

enum NumberMode: String, CaseIterable, Identifiable {
    case used, left
    var id: String { rawValue }
    var title: String { self == .used ? "Used" : "Remaining" }
}

enum Tab: String, CaseIterable, Identifiable {
    case usage = "Usage", activity = "Activity", proxy = "Proxy"
    var id: String { rawValue }
}

enum UpdatePhase: Equatable {
    case idle, checking, installing, restarting
    case failed(String)
    case done(String)

    var busy: Bool { self == .checking || self == .installing || self == .restarting }
}

/// What a reset confirmation is about: the account and, for Claude, the reset it names.
struct ResetTarget: Hashable {
    var account: String
    var grant: String?
}

/// Spending a banked reset from the popover.
enum ResetPhase: Equatable {
    case idle, applying
    /// A reset was spent.
    case done(String)
    /// The source answered and nothing was spent.
    case declined(String)
    /// No answer arrived, so the reset may or may not be spent.
    case uncertain(String)
}

/// Putting TeamClaude on this Mac.
enum SetupPhase: Equatable {
    case idle
    /// The install is running; the text names its current step.
    case installing(String)
    case failed(String)

    var busy: Bool { if case .installing = self { return true } else { return false } }
}

/// Renewing a sign-in from the popover.
enum ReconnectPhase: Equatable {
    case idle
    /// The login command runs and waits for the sign-in in the browser.
    case waiting
    case done(String)
    case failed(String)
}

@MainActor @Observable
final class AppModel {
    private(set) var config: AppConfig
    private(set) var configError: String?
    private(set) var accounts: [AccountSnapshot] = []
    private(set) var proxy = ProxySnapshot.down(nil)
    private(set) var history = History()
    private(set) var lastRefresh: Date?
    private(set) var refreshing = false
    private(set) var now = Date()

    private(set) var installedTeamClaude: String?
    /// The version in the proxy's npm prefix, read on refresh rather than on every view update.
    private(set) var teamClaudeOnDisk: String?
    private(set) var latestTeamClaude: String?
    private(set) var updateCheckedAt: Date?
    private(set) var updateError: String?
    private(set) var updatePhase: UpdatePhase = .idle
    var updateArmed = false

    private(set) var resetPhase: ResetPhase = .idle
    /// The account `resetPhase` is about.
    private(set) var resetSubject: String?
    /// The reset that is one click from being spent.
    var resetArmed: ResetTarget?
    /// Claude resets as Anthropic lists them, read on request. They hold the handles a spend names,
    /// so they stay in memory.
    private(set) var claudeResets: [String: ClaudeResetStatus] = [:]
    private(set) var claudeResetsLoading: Set<String> = []
    private(set) var claudeResetsError: [String: ClaudeResets.Failure] = [:]
    /// The calls to Anthropic that are waiting or on their way, and the rate limits in force.
    private(set) var apiQueue = APIQueue.Snapshot()

    /// Whether TeamClaude's CLI is on this Mac.
    private(set) var teamClaude: TeamClaudeInstall.Finding = .found("")
    private(set) var setupPhase: SetupPhase = .idle
    /// Why TeamClaude cannot be installed from here yet, such as a missing Node.
    private(set) var setupBlocker: String?
    /// TeamClaude's LaunchAgent is in place, so the proxy starts at login and can be restarted.
    private(set) var proxyServiceInstalled = true
    /// The accounts in TeamClaude's config, asked while the proxy is down and cannot say; nil when unknown.
    private(set) var storedAccounts: Int?
    /// A proxy answers although its CLI was not found, so it runs from somewhere this app does not look.
    private(set) var proxyElsewhere = false

    private(set) var reconnectPhase: ReconnectPhase = .idle
    /// The id of the sign-in `reconnectPhase` is about.
    private(set) var reconnectSubject: String?

    var tab: Tab = .usage
    var selectedAccount: String?
    private(set) var actionMessage: String?

    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle"); onChange?() }
    }
    var numberMode: NumberMode {
        didSet { defaults.set(numberMode.rawValue, forKey: "numberMode"); onChange?() }
    }
    var notificationsOn: Bool {
        didSet { defaults.set(notificationsOn, forKey: "notifications") }
    }
    /// The pool run-out time beside the menu bar glyph.
    var showRunOut: Bool {
        didSet { defaults.set(showRunOut, forKey: "showRunOut"); onChange?() }
    }

    /// Called whenever the menu bar item should redraw.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var alertState: AlertState?
    @ObservationIgnored private var codexFetchedAt: Date?
    @ObservationIgnored private var googleFetchedAt: Date?
    @ObservationIgnored private var nextUpdateCheck = Date.distantPast
    /// True while this app restarts the proxy, so the outage it causes does not notify.
    @ObservationIgnored private var proxyRestarting = false
    /// The redeem request still waiting for a verdict: a retry repeats it under the same key.
    @ObservationIgnored private var resetAttempt: (credit: String?, key: String)?
    /// Claude spend requests still waiting for a verdict, by account and reset.
    @ObservationIgnored private var claudeAttempts: [ResetTarget: String] = [:]
    /// The login command in flight, so it can be stopped.
    @ObservationIgnored private var reconnectHandle: ProcessHandle?
    /// The folders of the Node that runs TeamClaude, which go first on its PATH.
    @ObservationIgnored private var nodeFolders: [String] = []
    /// Every call this app makes to Anthropic goes through this one queue.
    @ObservationIgnored private let anthropicQueue = APIQueue()
    /// The running call per queue lane, so it can be cancelled.
    @ObservationIgnored private var claudeCalls: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastHistorySave = Date.distantPast
    /// Snapshot rendering reads live data but must not write state or notify.
    @ObservationIgnored private var readOnly = false

    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RunoutBar")
    static let historyURL = supportDir.appendingPathComponent("history.json")
    static let alertsURL = supportDir.appendingPathComponent("alerts.json")

    /// `--demo`: made-up accounts and usage instead of TeamClaude, Codex and Google AI. Nothing is read
    /// from or written to the real setup, and actions change nothing.
    let demo: Bool

    init(demo: Bool = CommandLine.arguments.contains("--demo")) {
        self.demo = demo
        let (config, error) = demo ? (DemoData.config, nil) : AppConfig.load()
        self.config = config
        self.configError = error
        menuBarStyle = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .bars
        numberMode = NumberMode(rawValue: UserDefaults.standard.string(forKey: "numberMode") ?? "") ?? .used
        notificationsOn = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true
        showRunOut = UserDefaults.standard.object(forKey: "showRunOut") as? Bool ?? true
        if demo {
            readOnly = true
            history = DemoData.history(now: now)
        } else {
            teamClaudeOnDisk = TeamClaudeUpdates.installedVersion(installDir: config.teamclaudeInstallDir)
            installedTeamClaude = teamClaudeOnDisk
            readTeamClaude()
        }
        Task { [weak self, updates = anthropicQueue.updates] in
            for await snapshot in updates { self?.apiQueue = snapshot }
        }
    }

    /// Reads and spends have their own limit at Anthropic, per account.
    enum ClaudeCall: String { case read, spend }

    static func lane(_ account: String, _ call: ClaudeCall) -> String { "\(call.rawValue) \(account)" }

    // MARK: - Lifecycle

    func start() {
        loadPersisted()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkTeamClaude()
                await self?.refresh()
                await self?.readPool()
                await self?.checkForUpdates(force: false)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func startForSnapshot() {
        readOnly = true
        loadPersisted()
    }

    func popoverWillShow() {
        now = Date()
        updateArmed = false
        clearResetPrompt()
        if lastRefresh.map({ Date().timeIntervalSince($0) > 20 }) ?? true {
            Task { await refresh() }
        }
    }

    /// In demo mode an action only says so.
    private func refusedInDemo() -> Bool {
        if demo { flash("Demo data: nothing was changed") }
        return demo
    }

    private func loadPersisted() {
        guard !demo else { return }
        if let saved = History.load(from: Self.historyURL) {
            history = saved
        }
        if let data = try? Data(contentsOf: Self.alertsURL) {
            alertState = try? JSONDecoder().decode(AlertState.self, from: data)
        }
    }

    func reloadConfig() {
        if refusedInDemo() { return }
        let (config, error) = AppConfig.load()
        self.config = config
        configError = error
        if Codex.locate(configured: config.codex) == nil {
            accounts.removeAll { $0.provider == .codex }
        }
        if GoogleAI.locate(configured: config.agy) == nil {
            accounts.removeAll { $0.provider == .google }
        }
        accounts = config.ordered(accounts)
        codexFetchedAt = nil
        googleFetchedAt = nil
        readInstalledVersion()
        readTeamClaude()
        onChange?()
        Task {
            while refreshing { try? await Task.sleep(for: .milliseconds(100)) }
            await refresh(force: true)
        }
    }

    // MARK: - Refresh

    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if demo {
            let stamp = Date()
            accounts = DemoData.accounts(now: stamp)
            proxy = DemoData.proxy(now: stamp)
            installedTeamClaude = proxy.version
            now = stamp
            lastRefresh = stamp
            onChange?()
            return
        }
        let config = self.config
        let env = toolEnvironment
        let wantCodex = force || codexFetchedAt.map { Date().timeIntervalSince($0) > 110 } ?? true
        let wantGoogle = force || googleFetchedAt.map { Date().timeIntervalSince($0) > GoogleAI.interval - 10 } ?? true

        async let claude = Self.fetchClaude(cli: teamclaudePath, config: config, env: env)
        async let codex = wantCodex ? Self.fetchCodex(config: config, env: env) : nil
        async let google = wantGoogle ? Self.fetchGoogle(config: config, env: env) : nil
        let (claudeResult, codexResult, googleResult) = await (claude, codex, google)
        let stamp = Date()

        var merged: [AccountSnapshot]
        switch claudeResult {
        case .success(let result):
            merged = result.accounts
            proxy = result.proxy
        case .failure(let error):
            // Keep the last values on screen, marked stale, while the proxy is down.
            proxy = .down(error.localizedDescription)
            let previous = accounts.filter { $0.provider == .claude }
            merged = previous.isEmpty
                ? config.accounts.keys.sorted().filter { $0 != AppConfig.codexKey && !GoogleAI.isKey($0) }
                    .map { AccountSnapshot.unavailable($0, provider: .claude, error: "Proxy not responding") }
                : previous.map { var account = $0; account.error = "Proxy not responding"; return account }
        }

        if wantCodex {
            codexFetchedAt = stamp
            if var codex = codexResult {
                if codex.error != nil, codex.windows.isEmpty, let last = accounts.first(where: { $0.provider == .codex }) {
                    // Keep the last values, with the new error and what it says about the login.
                    let (message, signIn) = (codex.error, codex.signIn)
                    codex = last
                    codex.error = message
                    if let signIn { codex.signIn = signIn }
                }
                merged.append(codex)
            }
        } else if let last = accounts.first(where: { $0.provider == .codex }) {
            merged.append(last)
        }

        let lastGoogle = accounts.filter { $0.provider == .google }
        if wantGoogle {
            googleFetchedAt = stamp
            if let googleResult { merged += GoogleAI.merge(googleResult, last: lastGoogle) }
        } else {
            merged += lastGoogle
        }

        accounts = config.ordered(merged)
        readInstalledVersion()
        if let running = proxy.version { installedTeamClaude = teamClaudeOnDisk ?? running }
        now = stamp
        lastRefresh = stamp
        history.record(accounts, now: stamp)
        saveHistoryIfDue()
        // A setup step that failed and was put right since, by hand or by a later start.
        if case .failed = setupPhase, teamClaudeFound, proxy.up { setupPhase = .idle }
        evaluateAlerts()
        onChange?()
    }

    private func readInstalledVersion() {
        let version = TeamClaudeUpdates.installedVersion(installDir: config.teamclaudeInstallDir)
        if version != teamClaudeOnDisk { teamClaudeOnDisk = version }
    }

    nonisolated static func fetchClaude(cli: String, config: AppConfig, env: [String: String]) async
        -> Result<(accounts: [AccountSnapshot], proxy: ProxySnapshot), Error> {
        do {
            let result = try await Shell.run(cli, ["status", "--json"],
                                             environment: env, timeout: 15)
            guard result.status == 0 else {
                throw RefreshError(message: result.timedOut ? "teamclaude status timed out" : result.tail(2))
            }
            return .success(try TeamClaudeStatus.parse(result.stdout, config: config))
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func fetchCodex(config: AppConfig, env: [String: String]) async -> AccountSnapshot? {
        guard let path = Codex.locate(configured: config.codex) else { return nil }
        do {
            var snapshot = try Codex.parse(try await Codex.fetchRateLimits(codex: path, environment: env))
            snapshot.signIn = SignIn(holder: .codex, account: AppConfig.codexKey)
            return snapshot
        } catch {
            var snapshot = AccountSnapshot.unavailable(AppConfig.codexKey, provider: .codex,
                                                       error: error.localizedDescription)
            // Codex states no end date for its login, so a lapse shows only as a refused read.
            if let failure = Codex.signInFailure(error) {
                snapshot.signIn = SignIn(holder: .codex, account: AppConfig.codexKey, failure: failure)
            }
            return snapshot
        }
    }

    /// The Google AI quota groups, or nil when the Antigravity CLI is not installed or is hidden.
    nonisolated static func fetchGoogle(config: AppConfig, env: [String: String]) async
        -> Result<[AccountSnapshot], Error>? {
        guard let path = GoogleAI.locate(configured: config.agy) else { return nil }
        do {
            return .success(try GoogleAI.parse(try await GoogleAI.fetchUsage(agy: path, environment: env)))
        } catch {
            return .failure(error)
        }
    }

    struct RefreshError: LocalizedError {
        var message: String
        var errorDescription: String? { message.isEmpty ? "Command failed" : message }
    }

    private func saveHistoryIfDue() {
        guard !readOnly, Date().timeIntervalSince(lastHistorySave) > 120 else { return }
        lastHistorySave = Date()
        try? history.save(to: Self.historyURL)
    }

    func saveNow() {
        guard !readOnly else { return }
        try? history.save(to: Self.historyURL)
    }

    private func evaluateAlerts() {
        guard !readOnly else { return }
        let (state, notices) = Alerts.evaluate(
            accounts: accounts, signIns: signIns, proxyUp: proxy.up,
            // A proxy that is not installed, or waits for its first account, is no outage, and its first
            // answer no recovery.
            proxyRestarting: proxyRestarting || !teamClaudeFound || needsAccount,
            latestTeamClaude: latestTeamClaude,
            installedTeamClaude: installedTeamClaude, previous: alertState, now: now,
            label: { [unowned self] in identity($0).label }, threshold: proxy.threshold)
        if state != alertState {
            alertState = state
            if let data = try? JSONEncoder().encode(state) {
                try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
                try? data.write(to: Self.alertsURL, options: .atomic)
            }
        }
        if notificationsOn { notifier.post(notices) }
    }

    func sendTestNotification() {
        notifier.post([Notice(title: "Runout Bar", body: "Notifications from the usage menu work.")])
    }

    // MARK: - Derived

    func identity(_ id: String) -> AccountIdentity {
        let index = accounts.firstIndex { $0.id == id } ?? accounts.count
        let account = accounts.first { $0.id == id }
        let known: Provider = id == AppConfig.codexKey ? .codex : GoogleAI.isKey(id) ? .google : .claude
        return config.identity(for: id, provider: account?.provider ?? known, index: index, title: account?.title)
    }

    func account(_ id: String?) -> AccountSnapshot? { accounts.first { $0.id == id } }

    var summary: PoolSummary {
        PoolSummary.make(accounts: accounts, history: history, now: now, threshold: proxy.threshold)
    }

    /// When the Claude pool runs out against the end of the work week; nil without fresh readings for every
    /// Claude account or enough history.
    var runOut: PoolRunOut? {
        PoolRunOut.make(accounts: accounts, history: history, now: now, threshold: proxy.threshold,
                        week: config.workWeek)
    }

    func pace(_ account: AccountSnapshot, _ window: LimitWindow) -> Pace? {
        guard !account.isStale(at: now) else { return nil }
        return PaceModel.pace(for: window, samples: history.samples(account.id), now: now, threshold: proxy.threshold)
    }

    /// An account's windows, one per line, for a tooltip.
    func windowsSummary(_ account: AccountSnapshot) -> String {
        let label = identity(account.id).label
        var lines: [String]
        switch account.provider {
        case .codex: lines = [label]
        case .google: lines = [account.covers.map { "\(label) · Google AI\n\($0)" } ?? "\(label) · Google AI"]
        case .claude: lines = [account.id == label ? label : "\(label) · \(account.id)"]
        }
        if let signIn = account.signIn, signIn.stage(at: now) > .ok {
            lines.append("\(signIn.headline(now: now)). \(signIn.explanation(now: now))")
        }
        if account.isStale(at: now) {
            lines.append(account.fetchedAt.map { "No fresh reading since \(Format.time($0))" } ?? "No reading")
        }
        for window in account.windows {
            guard let used = window.used else {
                lines.append("\(window.title): not reported")
                continue
            }
            var line = "\(window.title): \(Format.percent(used)) used"
            if let reset = window.resetsAt {
                line += " · resets \(Format.dayTime(reset)), in \(Format.until(reset, now: now))"
            }
            if window.isWeekly, let elapsed = window.elapsed(at: now) {
                line += " · even pace \(Format.percent(elapsed * 100))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Put text on the clipboard and say so in the footer.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied \(text)")
    }

    /// Banked resets across every account.
    var bankedResets: Int { accounts.reduce(0) { $0 + ($1.resets?.available ?? 0) } }

    var updateAvailable: Bool {
        guard teamClaudeFound else { return false }
        guard let latest = latestTeamClaude, let installed = installedTeamClaude else { return proxy.updateFlag }
        return SemVer.isNewer(latest, than: installed)
    }

    /// The running TeamClaude is the copy in this app's npm prefix, which is the one it can update.
    var updatesInPlace: Bool { demo || teamClaudeOnDisk != nil }

    /// Installed on disk but the proxy still runs the old version.
    var restartPending: Bool {
        guard let disk = teamClaudeOnDisk, let running = proxy.version, proxy.up else { return false }
        return SemVer.isNewer(disk, than: running)
    }

    // MARK: - Actions

    private func flash(_ message: String) {
        actionMessage = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if actionMessage == message { actionMessage = nil }
        }
    }

    func route(to account: String) async {
        if refusedInDemo() { return }
        let result = try? await Shell.run(teamclaudePath, ["switch", account], environment: toolEnvironment, timeout: 15)
        flash(result?.status == 0 ? "Routing new requests to \(identity(account).label)" : "Could not switch account")
        await refresh()
    }

    func setProbe(_ seconds: Int) async {
        if refusedInDemo() { return }
        let argument = seconds == 0 ? "off" : String(seconds)
        let result = try? await Shell.run(teamclaudePath, ["probe", argument], environment: toolEnvironment, timeout: 15)
        if result?.status != 0 { flash("Could not change the usage check") }
        await refresh()
    }

    /// Drop the confirmation and any finished result; a request in flight keeps its state.
    func clearResetPrompt() {
        resetArmed = nil
        if resetPhase != .applying {
            resetPhase = .idle
            resetSubject = nil
        }
    }

    /// The spend state as one account's view should show it.
    func resetPhase(for account: String) -> ResetPhase { resetSubject == account ? resetPhase : .idle }

    /// Spend one banked Codex reset through the Codex app server. It cannot be undone, so the view
    /// asks first. Without a verdict the request is kept, until the app quits, and the next try repeats it.
    func applyCodexReset() async {
        resetArmed = nil
        if refusedInDemo() { return }
        guard resetPhase != .applying, let account = accounts.first(where: { $0.provider == .codex }),
              let resets = account.resets, let path = Codex.locate(configured: config.codex) else { return }
        // An attempt without a verdict is repeated as it was. Naming the next credit under a new key
        // could spend a second reset when the first request did go through.
        let (credit, key) = resetAttempt ?? (resets.nextGrant?.id, UUID().uuidString)
        resetAttempt = (credit, key)
        resetSubject = account.id
        resetPhase = .applying
        do {
            let outcome = try await Codex.consumeResetCredit(codex: path, environment: toolEnvironment,
                                                             creditID: credit, idempotencyKey: key)
            resetAttempt = nil
            switch outcome {
            case .reset: resetPhase = .done("Codex limits were reset. One reset spent.")
            case .alreadyRedeemed: resetPhase = .done("That reset had already gone through.")
            case .nothingToReset: resetPhase = .declined("Codex has no limit to reset right now. Nothing was spent.")
            case .noCredit: resetPhase = .declined("Codex reports no reset to spend. Nothing was spent.")
            }
        } catch {
            resetPhase = .uncertain("No answer from Codex (\(error.localizedDescription)). The reset may or may not "
                + "have been spent. Trying again repeats the same request, so it cannot spend a second one.")
        }
        await refresh(force: true)
    }

    /// Read one Claude account's resets from Anthropic. Spends nothing. The call joins the queue:
    /// when Anthropic rate-limits it, it waits there and goes out again once the limit clears. An
    /// earlier reading stays until a new one arrives.
    @discardableResult
    func loadClaudeResets(_ account: String) -> Task<Void, Never>? {
        if demo {
            claudeResets[account] = DemoData.resets(now: Date())
            return nil
        }
        let lane = Self.lane(account, .read)
        guard claudeCalls[lane] == nil else { return claudeCalls[lane] }
        claudeResetsLoading.insert(account)
        claudeResetsError[account] = nil
        let env = toolEnvironment
        let node = TeamClaudeInstall.locateTool("node", configured: config.node, path: env["PATH"] ?? "") ?? config.node
        let installDir = config.teamclaudeInstallDir
        let packageDir = TeamClaudePool.packageDir(cli: teamclaudePath, installDir: installDir)
        let queue = anthropicQueue
        // A snapshot run does not wait out a rate limit; it falls back to a sample listing.
        let maxWait: TimeInterval? = readOnly ? 0 : nil
        let task = Task {
            do {
                claudeResets[account] = try await queue.run(lane: lane, label: "Read resets: \(identity(account).label)",
                                                            maxWait: maxWait) {
                    try await ClaudeResets.list(node: node, installDir: installDir, packageDir: packageDir,
                                                account: account, environment: env)
                }
            } catch is CancellationError {
                // The user stopped waiting.
            } catch let failure as ClaudeResets.Failure {
                claudeResetsError[account] = failure
            } catch {
                claudeResetsError[account] = ClaudeResets.Failure(message: "Could not run node: \(error.localizedDescription)")
            }
            claudeResetsLoading.remove(account)
            claudeCalls[lane] = nil
        }
        claudeCalls[lane] = task
        return task
    }

    /// Take a queued or held call out of the queue. A call already on its way finishes.
    func cancelClaudeCall(_ account: String, _ call: ClaudeCall) {
        claudeCalls[Self.lane(account, call)]?.cancel()
    }

    /// Where an account's call stands in the queue, or nil when it has none there.
    func queueState(_ account: String, _ call: ClaudeCall) -> APIQueue.State? {
        apiQueue.entry(lane: Self.lane(account, call))?.state
    }

    /// When Anthropic's rate limit on this kind of call clears for the account, if one is known.
    func rateLimitedUntil(_ account: String, _ call: ClaudeCall) -> Date? {
        apiQueue.holds[Self.lane(account, call)]
    }

    /// A listing for snapshot rendering, when Anthropic rate-limits the live read.
    func showClaudeResetsForSnapshot(_ account: String, _ status: ClaudeResetStatus) {
        guard readOnly else { return }
        claudeResets[account] = status
        claudeResetsError[account] = nil
    }

    /// A queue state for snapshot rendering.
    func showQueueForSnapshot(_ queue: APIQueue.Snapshot, loading: Set<String> = [], applying: String? = nil) {
        guard readOnly else { return }
        apiQueue = queue
        claudeResetsLoading = loading
        resetSubject = applying
        resetPhase = applying == nil ? .idle : .applying
    }

    /// Spend the armed Claude reset by asking Anthropic directly, with the token TeamClaude stores.
    /// It cannot be undone, so the view asks first. A rate-limited request waits in the queue and
    /// goes out again under the same request id. Without a verdict the request id is kept, until
    /// the app quits, and the next try on that reset repeats it.
    func applyClaudeReset() {
        if refusedInDemo() {
            resetArmed = nil
            return
        }
        guard resetPhase != .applying, let target = resetArmed, let grant = target.grant else { return }
        resetArmed = nil
        let requestID = claudeAttempts[target] ?? UUID().uuidString
        claudeAttempts[target] = requestID
        resetSubject = target.account
        resetPhase = .applying
        let lane = Self.lane(target.account, .spend)
        let env = toolEnvironment
        let node = TeamClaudeInstall.locateTool("node", configured: config.node, path: env["PATH"] ?? "") ?? config.node
        let installDir = config.teamclaudeInstallDir
        let packageDir = TeamClaudePool.packageDir(cli: teamclaudePath, installDir: installDir)
        let queue = anthropicQueue
        let sent = OSAllocatedUnfairLock(initialState: false)
        claudeCalls[lane] = Task {
            var spent = false
            do {
                let verdict = try await queue.run(lane: lane, label: "Spend a reset: \(identity(target.account).label)") {
                    sent.withLock { $0 = true }
                    return try await ClaudeResets.claim(node: node, installDir: installDir, packageDir: packageDir,
                                                        account: target.account, grantID: grant, requestID: requestID,
                                                        environment: env)
                }
                claudeAttempts[target] = nil
                switch verdict {
                case .spent(let cleared, let left, let replay):
                    spent = true
                    var text = replay ? "That request had already gone through: one reset was spent."
                        : "Reset spent" + (cleared.isEmpty ? "." : ": cleared \(ClaudeResets.limits(cleared)).")
                    if let left { text += " \(left) left on this grant." }
                    resetPhase = .done(text + " TeamClaude sees the new limits at its next usage check.")
                case .declined(let reason):
                    resetPhase = .declined("Anthropic answered \(reason). Nothing was spent.")
                }
            } catch is CancellationError {
                if sent.withLock({ $0 }) {
                    resetPhase = .uncertain("Stopped waiting. Anthropic rate-limited the request and gave no verdict, "
                        + "so the reset may or may not have been spent. Trying again repeats the same request, so it "
                        + "cannot spend a second one.")
                } else {
                    claudeAttempts[target] = nil
                    resetPhase = .declined("Stopped before anything was sent. Nothing was spent.")
                }
            } catch let failure as ClaudeResets.Failure where failure.sent {
                resetPhase = .uncertain("No verdict from Anthropic (\(failure.message)). The reset may or may not have "
                    + "been spent. Trying again repeats the same request, so it cannot spend a second one.")
            } catch {
                claudeAttempts[target] = nil
                resetPhase = .declined("Nothing was sent: \(error.localizedDescription).")
            }
            claudeCalls[lane] = nil
            // The listing no longer matches after a spend; an unanswered one keeps it for the retry.
            if spent { claudeResets[target.account] = nil }
            await refresh(force: true)
        }
    }

    // MARK: - Sign-ins

    /// Every sign-in the readings and the routing depend on. Multiple rows can share one login (such as
    /// Google AI's quota groups), so each sign-in is listed once.
    var signIns: [SignIn] {
        var seen: Set<String> = []
        return (accounts.compactMap(\.signIn) + proxy.codexSignIns).filter { seen.insert($0.id).inserted }
    }

    /// The sign-ins to act on, the most urgent first, with the one being renewed kept in view.
    var signInsDue: [SignIn] {
        signIns.filter { $0.stage(at: now) > .ok || $0.id == reconnectSubject }.sorted {
            let (a, b) = ($0.stage(at: now), $1.stage(at: now))
            return a != b ? a > b : ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
        }
    }

    func signInLabel(_ signIn: SignIn) -> String {
        Alerts.signInTitle(signIn) { [unowned self] in identity($0).label }
    }

    /// The site a sign-in happens on.
    func signInSite(_ signIn: SignIn) -> String {
        switch signIn.holder {
        case .teamclaude: return "claude.ai"
        case .teamclaudeCodex, .codex: return "chatgpt.com"
        case .google: return "accounts.google.com"
        }
    }

    /// The account to sign in as, where its name says so. The Codex and Antigravity CLI logins go by no name here.
    func signInIdentity(_ signIn: SignIn) -> String? {
        signIn.holder == .codex || signIn.holder == .google || signIn.account.isEmpty ? nil : signIn.account
    }

    /// Stands for the account a first sign-in adds, which has no name yet.
    static let newAccount = SignIn(holder: .teamclaude, account: "")

    /// TeamClaude is installed and has no account to route to.
    var needsAccount: Bool {
        guard teamClaudeFound, !setupPhase.busy else { return false }
        // A proxy with an empty pool exits as it starts, so while it is down its config answers.
        return proxy.up ? proxy.accountCount == 0 : storedAccounts == 0
    }

    func reconnectPhase(for signIn: SignIn) -> ReconnectPhase { reconnectSubject == signIn.id ? reconnectPhase : .idle }

    /// Open the popover's view of a sign-in: its account, or the Proxy tab for an account only the proxy has.
    func show(signIn id: String) {
        guard let signIn = signIns.first(where: { $0.id == id }) else { return }
        if signIn.holder != .teamclaudeCodex,
           let target = account(signIn.account) ?? accounts.first(where: { $0.signIn?.id == id }) {
            tab = .usage
            selectedAccount = target.id
        } else {
            selectedAccount = nil
            tab = .proxy
        }
    }

    /// Drop a finished result; a login in flight keeps its state.
    func clearReconnect() {
        guard reconnectPhase != .waiting else { return }
        reconnectPhase = .idle
        reconnectSubject = nil
    }

    func cancelReconnect() { reconnectHandle?.cancel() }

    /// Run a sign-in's login command, which opens the browser and waits for the sign-in to come back.
    /// Nil when the wait was cancelled; the inner value is nil when the command could not start.
    private func runLogin(_ signIn: SignIn, executable: String) async -> ProcessResult?? {
        let handle = ProcessHandle()
        reconnectHandle = handle
        reconnectSubject = signIn.id
        reconnectPhase = .waiting
        var environment = toolEnvironment
        // This app runs beside the browser, whatever the environment it was started from says.
        environment["TEAMROUTER_REMOTE"] = "0"
        environment["TEAMCLAUDE_REMOTE"] = "0"
        let result = try? await Shell.run(executable, signIn.loginArguments, environment: environment,
                                          timeout: Self.loginTimeout, handle: handle)
        reconnectHandle = nil
        if result?.cancelled == true {
            reconnectPhase = .idle
            reconnectSubject = nil
            flash("Sign-in cancelled")
            return nil
        }
        return .some(result)
    }

    /// Why a login that changed nothing ended as it did.
    private func loginFailure(_ result: ProcessResult?, unchanged: String) -> String {
        let output = (result?.errorOutput ?? "") + "\n" + (result?.output ?? "")
        return Reconnect.failureReason(output)
            ?? (result?.timedOut == true ? "no sign-in arrived in time"
                : result?.status == 0 ? unchanged
                : result == nil ? "the login command could not be started" : "the login command failed")
    }

    /// The browser took the focus and the popover closed, so a login's result also goes out as a notification.
    private func announce(_ title: String, _ body: String, signIn: String? = nil) {
        guard notificationsOn, !readOnly, !body.isEmpty else { return }
        notifier.post([Notice(title: title, body: body, signIn: signIn)])
    }

    /// Sign in again by running the holder's own login command. TeamClaude takes the new tokens with a reload,
    /// not a restart. The login renews the account the browser is signed in to, so the result is read from
    /// what changed, not from what was asked.
    func reconnect(_ signIn: SignIn) async {
        if refusedInDemo() { return }
        guard reconnectPhase != .waiting, !setupPhase.busy, !signIn.manual else { return }
        if signIn.holder == .google {
            await reconnectGoogle(signIn)
            return
        }
        let adding = signIn.id == Self.newAccount.id
        // A proxy that is down for want of an account has nothing to compare: its config says what was added.
        if adding, !proxy.up {
            await addFirstAccount()
            return
        }
        let label = adding ? "Claude account" : signInLabel(signIn)
        guard let executable = signIn.holder == .codex ? Codex.locate(configured: config.codex) : teamclaudePath else {
            reconnectSubject = signIn.id
            reconnectPhase = .failed("The Codex CLI was not found. Set \"codex\" in the config.")
            return
        }
        let before = signIns
        guard let result = await runLogin(signIn, executable: executable) else { return }
        let succeeded = result?.status == 0
        // TeamClaude's Codex login saves the sign-in without telling the running proxy, so this app does.
        if succeeded, signIn.holder == .teamclaudeCodex, let (node, package) = poolHelper {
            _ = await TeamClaudePool.reload(node: node, packageDir: package, environment: toolEnvironment)
        }
        // A refresh already under way read the old state; wait for it, then read again.
        while refreshing { try? await Task.sleep(for: .milliseconds(100)) }
        await refresh(force: true)

        switch Reconnect.outcome(target: signIn, before: before, after: signIns, succeeded: succeeded) {
        case .renewed(let until):
            reconnectPhase = .done("Signed in again." + (until.map { " Good until \(Format.day($0))." } ?? ""))
        case .renewedOther(let names) where adding:
            reconnectPhase = .done("Added \(names.joined(separator: ", ")).")
        case .renewedOther(let names):
            let who = names.map { identity($0).label == $0 ? $0 : "\(identity($0).label) (\($0))" }.joined(separator: ", ")
            let wanted = signInIdentity(signIn).map { " as \($0)" } ?? ""
            reconnectPhase = .failed("The browser was signed in to another account, so the sign-in went to \(who). "
                + "Sign in to \(signInSite(signIn))\(wanted) and reconnect again.")
        case .unchanged:
            let unchanged = adding ? "the login finished, but no account appeared"
                : "the login finished, but this sign-in did not change"
            reconnectPhase = .failed("Not \(adding ? "added" : "renewed"): \(loginFailure(result, unchanged: unchanged)).")
        }
        switch reconnectPhase {
        case .done(let text), .failed(let text): announce(label, text, signIn: signIn.id)
        default: break
        }
        // A first account shows as its own row, so its result needs no banner.
        if adding, case .done(let text) = reconnectPhase {
            reconnectPhase = .idle
            reconnectSubject = nil
            flash(text)
        }
        onChange?()
    }

    /// Sign in with Google through `agy acp --stdio`, which opens the default browser with a localhost
    /// callback so no authorization code has to be copied back.
    private func reconnectGoogle(_ signIn: SignIn) async {
        let label = signInLabel(signIn)
        guard let executable = GoogleAI.locate(configured: config.agy) else {
            reconnectSubject = signIn.id
            reconnectPhase = .failed("The Antigravity CLI was not found. Set \"agy\" in the config.")
            return
        }
        let before = signIns
        let handle = ProcessHandle()
        reconnectHandle = handle
        reconnectSubject = signIn.id
        reconnectPhase = .waiting
        let outcome = await GoogleAI.signIn(agy: executable, environment: toolEnvironment,
                                            timeout: Self.loginTimeout, handle: handle)
        reconnectHandle = nil
        if outcome == .cancelled {
            reconnectPhase = .idle
            reconnectSubject = nil
            flash("Sign-in cancelled")
            return
        }
        while refreshing { try? await Task.sleep(for: .milliseconds(100)) }
        await refresh(force: true)

        switch Reconnect.outcome(target: signIn, before: before, after: signIns, succeeded: outcome == .succeeded) {
        case .renewed:
            reconnectPhase = .done(signIn.failure?.code == "signed_out" ? "Signed in." : "Signed in again.")
        case .renewedOther(let names):
            reconnectPhase = .done("Signed in (\(names.joined(separator: ", "))).")
        case .unchanged:
            let reason: String
            if case .failed(let message) = outcome { reason = message }
            else { reason = "the sign-in finished, but the CLI still reports no login" }
            let verb = signIn.failure?.code == "signed_out" ? "signed in" : "renewed"
            reconnectPhase = .failed("Not \(verb): \(reason).")
        }
        switch reconnectPhase {
        case .done(let text), .failed(let text): announce(label, text, signIn: signIn.id)
        default: break
        }
        onChange?()
    }

    /// The first account of a TeamClaude whose proxy is not up: the login saves it to the config, and only
    /// then can the proxy start.
    private func addFirstAccount() async {
        let signIn = Self.newAccount
        guard let result = await runLogin(signIn, executable: teamclaudePath) else { return }
        readTeamClaude()
        storedAccounts = await poolCount()
        // Where the config cannot be asked, a login that ended well is taken at its word.
        guard storedAccounts ?? (result?.status == 0 ? 1 : 0) > 0 else {
            let reason = loginFailure(result, unchanged: "the login finished, but no account was saved")
            reconnectPhase = .failed("Not added: \(reason).")
            announce("Claude account", "Not added: \(reason).")
            onChange?()
            return
        }
        reconnectPhase = .idle
        reconnectSubject = nil
        do {
            try await startProxyService()
            setupPhase = .idle
            flash("Account added. TeamClaude is running.")
            announce("Runout Bar", "The Claude account was added and TeamClaude is running. It starts at login.")
        } catch {
            setupPhase = .failed(error.localizedDescription)
            announce("Runout Bar", "The Claude account was added. \(error.localizedDescription)")
        }
        onChange?()
    }

    /// TeamClaude's own login gives up after two minutes; Codex states no limit.
    static let loginTimeout: TimeInterval = 300

    /// A reconnect state for snapshot rendering.
    func showReconnectForSnapshot(_ subject: String?, _ phase: ReconnectPhase) {
        guard readOnly else { return }
        reconnectSubject = subject
        reconnectPhase = phase
    }

    // MARK: - TeamClaude install

    var teamClaudeFound: Bool { if case .found = teamClaude { return true } else { return false } }

    /// The CLI to run: where it was found, or where the config says it goes.
    var teamclaudePath: String {
        if case .found(let path) = teamClaude, !path.isEmpty { return path }
        return AppConfig.expand(config.teamclaude)
    }

    /// The environment TeamClaude and npm run in: their scripts start with `env node`.
    private var toolEnvironment: [String: String] { Shell.environment(first: nodeFolders) }

    /// Set once TeamClaude was on this Mac, or this app started to install it. From then on a missing
    /// TeamClaude was removed by someone, and stays removed until they click Install.
    private static let seenKey = "teamClaudeSeen"

    /// What the disk says about TeamClaude: its CLI, its LaunchAgent, its accounts and its Node.
    private func readTeamClaude() {
        let finding = TeamClaudeInstall.find(config: config)
        if finding != teamClaude { teamClaude = finding }
        let agent = TeamClaudeInstall.launchAgentURL(home: NSHomeDirectory(), label: config.proxyService)
        let service = FileManager.default.fileExists(atPath: agent.path)
        if service != proxyServiceInstalled { proxyServiceInstalled = service }
        nodeFolders = TeamClaudeInstall.nodeFolders(config: config, cli: teamclaudePath)
    }

    /// The Node and the TeamClaude package that answer about the pool, when both are found.
    private var poolHelper: (node: String, package: String)? {
        guard teamClaudeFound,
              let node = TeamClaudeInstall.locateTool("node", configured: config.node, path: toolEnvironment["PATH"] ?? ""),
              let package = TeamClaudePool.packageDir(cli: teamclaudePath, installDir: config.teamclaudeInstallDir)
        else { return nil }
        return (node, package)
    }

    private func poolCount() async -> Int? {
        guard let (node, package) = poolHelper else { return nil }
        return await TeamClaudePool.accountCount(node: node, packageDir: package, environment: toolEnvironment)
    }

    /// Ask how many accounts TeamClaude has while its proxy is down: one with none exits as it starts, and
    /// then the next step is an account, not a restart.
    func readPool() async {
        guard !readOnly, teamClaudeFound, !proxy.up, !setupPhase.busy else { return }
        let count = await poolCount()
        if count != storedAccounts {
            storedAccounts = count
            onChange?()
        }
    }

    /// Look for TeamClaude, and install it without asking on a Mac that shows no sign of it.
    func checkTeamClaude() async {
        guard !readOnly, !setupPhase.busy else { return }
        readTeamClaude()
        guard case .missing(let traces) = teamClaude else {
            if !defaults.bool(forKey: Self.seenKey) { defaults.set(true, forKey: Self.seenKey) }
            if setupBlocker != nil { setupBlocker = nil }
            if proxyElsewhere { proxyElsewhere = false }
            return
        }
        // A proxy that answers, or a dashboard on another machine, runs from somewhere this app cannot see,
        // such as a container. Installing a second copy beside it is not this app's call.
        var elsewhere = TeamClaudeInstall.localEndpoint(dashboard: config.dashboard) == nil
        if !elsewhere { elsewhere = await TeamClaudeInstall.proxyAnswers(dashboard: config.dashboard) }
        if elsewhere != proxyElsewhere { proxyElsewhere = elsewhere }
        // Files of another copy, a failed attempt or a TeamClaude that was here before leave the choice to a click.
        guard !elsewhere, !traces, setupPhase == .idle, !defaults.bool(forKey: Self.seenKey) else { return }
        await installTeamClaude(automatic: true)
    }

    /// Install the latest release into its npm prefix and link the CLI. With accounts already in its config,
    /// TeamClaude then installs its own LaunchAgent, which starts the proxy now and at login; without one the
    /// proxy would exit as it starts, so that step waits for the first account.
    func installTeamClaude(automatic: Bool = false) async {
        if refusedInDemo() { return }
        guard !setupPhase.busy else { return }
        // Busy from here on, ahead of the first wait, so a second click or the minute's check starts no second run.
        setupPhase = .installing("Checking Node")
        let path = toolEnvironment["PATH"] ?? ""
        guard let npm = TeamClaudeInstall.locateTool("npm", configured: config.npm, path: path),
              let node = TeamClaudeInstall.locateTool("node", configured: config.node, path: path) else {
            setupPhase = .idle
            setupBlocker = "It needs Node.js \(TeamClaudeInstall.minimumNode) or later, and none was found. "
                + "Install Node, for example with: brew install node"
            onChange?()
            return
        }
        let version = (try? await Shell.run(node, ["--version"], timeout: 10))?.output ?? ""
        guard let major = TeamClaudeInstall.nodeMajor(version), major >= TeamClaudeInstall.minimumNode else {
            let found = version.trimmingCharacters(in: .whitespacesAndNewlines)
            setupPhase = .idle
            setupBlocker = "It needs Node.js \(TeamClaudeInstall.minimumNode) or later; \(node) is \(found.isEmpty ? "not answering" : found)."
            onChange?()
            return
        }
        setupBlocker = nil
        // npm runs with the Node that was just checked, wherever the two were found.
        let environment = Shell.environment(first: [node, npm].map { ($0 as NSString).deletingLastPathComponent })
        setupPhase = .installing("Reading the latest version")
        var installed: String?
        do {
            let latest = try await TeamClaudeUpdates.latestVersion()
            let arguments = try TeamClaudeUpdates.installArguments(version: latest,
                                                                   installDir: config.teamclaudeInstallDir)
            // From here the Mac changes: an automatic install happens once.
            defaults.set(true, forKey: Self.seenKey)
            setupPhase = .installing("Installing TeamClaude \(latest) with npm")
            let result = try await Shell.run(npm, arguments, environment: environment, timeout: 300)
            guard result.status == 0 else { throw TeamClaudeInstall.InstallError.npmFailed(result.tail()) }
            try TeamClaudeInstall.link(cli: config.teamclaude, installDir: config.teamclaudeInstallDir)
            readTeamClaude()
            guard teamClaudeFound else {
                throw TeamClaudeInstall.InstallError.npmFailed("the CLI is not at \(config.teamclaude)")
            }
            readInstalledVersion()
            installedTeamClaude = teamClaudeOnDisk
            installed = latest
            storedAccounts = await poolCount()
            // An empty pool gets its account first: the Add Account step starts the proxy.
            if storedAccounts != 0 { try await startProxyService() }
            setupPhase = .idle
            flash("TeamClaude \(latest) installed")
        } catch {
            setupPhase = .failed(error.localizedDescription)
        }
        // An automatic install runs with the popover closed, so its result goes out as a notification.
        if automatic {
            if case .failed(let reason) = setupPhase {
                announce("Runout Bar", installed == nil ? "TeamClaude was not installed: \(reason)"
                    : "TeamClaude \(installed ?? "") was installed. \(reason)")
            } else if let installed {
                announce("Runout Bar", needsAccount
                    ? "TeamClaude \(installed) was installed. Open Runout Bar to add a Claude account."
                    : "TeamClaude \(installed) was installed and starts at login.")
            }
        }
        onChange?()
    }

    /// Give an installed TeamClaude its LaunchAgent, for a copy that was only ever started by hand.
    func installProxyService() async {
        if refusedInDemo() { return }
        // `service install` reloads the LaunchAgent, which would restart a proxy that runs.
        guard !setupPhase.busy, teamClaudeFound, !proxy.up else { return }
        do {
            try await startProxyService()
            setupPhase = .idle
            flash("TeamClaude starts at login")
        } catch {
            setupPhase = .failed(error.localizedDescription)
        }
        onChange?()
    }

    /// Another try at a setup step that failed.
    func retrySetup() async {
        guard teamClaudeFound else {
            await installTeamClaude()
            return
        }
        guard !setupPhase.busy else { return }
        setupPhase = .idle
        if proxy.up || needsAccount { return }
        if proxyServiceInstalled { await restartProxy() } else { await installProxyService() }
        if !proxy.up, setupPhase == .idle { setupPhase = .failed(TeamClaudeInstall.InstallError.notStarted.localizedDescription) }
        onChange?()
    }

    /// Get a stopped proxy running: `teamclaude service install` writes and loads the LaunchAgent where there
    /// is none, and one that is in place starts the proxy again by itself. Then wait for the proxy to answer.
    private func startProxyService() async throws {
        // A proxy that runs already, started by hand or from elsewhere, is left as it is.
        while refreshing { try? await Task.sleep(for: .milliseconds(100)) }
        await refresh()
        if proxy.up { return }
        if !proxyServiceInstalled {
            setupPhase = .installing("Setting the proxy to start at login")
            let result = try await Shell.run(teamclaudePath, TeamClaudeInstall.serviceArguments,
                                             environment: toolEnvironment, timeout: 90)
            guard result.status == 0 else { throw TeamClaudeInstall.InstallError.serviceFailed(result.tail()) }
            proxyServiceInstalled = true
        }
        setupPhase = .installing("Starting the proxy")
        // The proxy was never up, so its first answer is no recovery to announce.
        proxyRestarting = true
        defer { proxyRestarting = false }
        let deadline = Date().addingTimeInterval(Self.proxyStartWait)
        repeat {
            await refresh()
            if proxy.up { return }
            try? await Task.sleep(for: .seconds(2))
        } while Date() < deadline
        throw TeamClaudeInstall.InstallError.notStarted
    }

    /// launchd starts a proxy that exited again after ten seconds, so this covers a few starts.
    static let proxyStartWait: TimeInterval = 45

    func addAccount() async { await reconnect(Self.newAccount) }

    /// An account right after a banked reset, for snapshot rendering: its weekly window is low again and
    /// its session window has filled since.
    func showResetSpentForSnapshot() {
        guard readOnly, let index = accounts.firstIndex(where: { $0.provider == .claude && $0.window("5h") != nil })
        else { return }
        for at in accounts[index].windows.indices {
            let window = accounts[index].windows[at]
            accounts[index].windows[at].used = window.id == "5h" ? proxy.threshold : window.isWeekly ? 17 : window.used
            if window.id == "5h" { accounts[index].windows[at].resetsAt = now.addingTimeInterval(3 * 3600 + 120) }
            accounts[index].windows[at].forecast = nil
        }
        accounts[index].unavailable = "quota"
        accounts[index].sessions = 0
    }

    /// A setup state for snapshot rendering. `noAccounts` leaves the proxy running without a Claude account.
    func showSetupForSnapshot(_ finding: TeamClaudeInstall.Finding, _ phase: SetupPhase, blocker: String? = nil,
                              noAccounts: Bool = false, elsewhere: Bool = false) {
        guard readOnly else { return }
        teamClaude = finding
        setupPhase = phase
        setupBlocker = blocker
        proxyElsewhere = elsewhere
        storedAccounts = noAccounts ? 0 : nil
        if noAccounts {
            accounts.removeAll { $0.provider == .claude }
            // A proxy with an empty pool is not running.
            proxy = .down("No accounts configured.")
        }
        if case .missing = finding { proxy = .down("TeamClaude is not installed") }
    }

    /// A signed-out Google AI state for snapshot rendering.
    func showGoogleSignedOutForSnapshot() {
        guard readOnly else { return }
        accounts.removeAll { $0.provider == .google }
        accounts += GoogleAI.merge(
            .failure(GoogleAI.ReadError("The Antigravity CLI is not signed in", signedOut: true)), last: [])
        accounts = config.ordered(accounts)
    }

    private func kickstartProxy() async throws {
        let target = "gui/\(getuid())/\(config.proxyService)"
        let result = try await Shell.run("/bin/launchctl", ["kickstart", "-k", target], timeout: 20)
        guard result.status == 0 else { throw TeamClaudeUpdates.UpdateError.restartFailed(result.tail(2)) }
    }

    func restartProxy() async {
        if refusedInDemo() { return }
        proxyRestarting = true
        defer { proxyRestarting = false }
        do {
            try await kickstartProxy()
            flash("Proxy restarted")
        } catch {
            flash(error.localizedDescription)
        }
        // Let it bind before reading status; a few tries cover a slow start.
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(2))
            await refresh(force: true)
            if proxy.up { break }
        }
    }

    func checkForUpdates(force: Bool) async {
        if demo {
            latestTeamClaude = "1.1.31"  // one release ahead, so the update card shows
            updateCheckedAt = Date()
            onChange?()
            return
        }
        if !force, Date() < nextUpdateCheck { return }
        if force { updatePhase = .checking }
        do {
            latestTeamClaude = try await TeamClaudeUpdates.latestVersion()
            updateError = nil
            nextUpdateCheck = Date().addingTimeInterval(6 * 3600)
        } catch {
            updateError = error.localizedDescription
            nextUpdateCheck = Date().addingTimeInterval(15 * 60)  // offline at login, registry hiccup
        }
        updateCheckedAt = Date()
        readInstalledVersion()
        installedTeamClaude = teamClaudeOnDisk ?? proxy.version
        if force { updatePhase = .idle }
        evaluateAlerts()
        onChange?()
    }

    /// Install the latest release into the proxy's npm prefix, restart the
    /// LaunchAgent, and wait for the proxy to report the new version.
    func updateTeamClaude() async {
        updateArmed = false
        if refusedInDemo() { return }
        guard let latest = latestTeamClaude else { return }
        updatePhase = .installing
        do {
            let arguments = try TeamClaudeUpdates.installArguments(version: latest,
                                                                   installDir: config.teamclaudeInstallDir)
            let environment = toolEnvironment
            // npm is looked for as the first install does, so a Mac that could install can also update.
            guard let npm = TeamClaudeInstall.locateTool("npm", configured: config.npm, path: environment["PATH"] ?? "") else {
                throw TeamClaudeUpdates.UpdateError.installFailed("npm was not found. Set \"npm\" in the config.")
            }
            let result = try await Shell.run(npm, arguments, environment: environment, timeout: 300)
            guard result.status == 0 else { throw TeamClaudeUpdates.UpdateError.installFailed(result.tail()) }
            readInstalledVersion()
            guard teamClaudeOnDisk == latest else {
                throw TeamClaudeUpdates.UpdateError.installFailed("package.json still reports \(teamClaudeOnDisk ?? "nothing")")
            }
            installedTeamClaude = latest
            updatePhase = .restarting
            proxyRestarting = true
            defer { proxyRestarting = false }
            try await kickstartProxy()
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                await refresh(force: true)
                if proxy.up, proxy.version == latest { break }
            }
            updatePhase = proxy.up && proxy.version == latest
                ? .done(latest)
                : .failed("Installed \(latest), but the proxy reports \(proxy.up ? proxy.version ?? "no version" : "not running")")
        } catch {
            updatePhase = .failed(error.localizedDescription)
        }
        onChange?()
    }

    func openLog() {
        if refusedInDemo() { return }
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: AppConfig.expand(config.proxyLog))], withApplicationAt: console,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func openDashboard() {
        if refusedInDemo() { return }
        if let url = URL(string: config.dashboard) { NSWorkspace.shared.open(url) }
    }

    /// Open the config file, writing a starter one from the current accounts first.
    func openConfig() {
        if refusedInDemo() { return }
        let url = AppConfig.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            var starter: [String: Any] = [:]
            var styles: [String: Any] = [:]
            for account in accounts {
                let identity = identity(account.id)
                var style: [String: Any] = ["letter": identity.letter, "label": identity.label,
                                            "symbol": identity.symbol, "color": identity.color]
                if account.provider == .claude { style["noFiveHourLimit"] = account.sessionNote == .noLimit }
                styles[account.id] = style
            }
            starter["accounts"] = styles
            starter["order"] = accounts.map(\.id)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: starter, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url)
            }
        }
        NSWorkspace.shared.open(url)
    }
}
