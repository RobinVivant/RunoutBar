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
    @ObservationIgnored private var nextUpdateCheck = Date.distantPast
    /// True while this app restarts the proxy, so the outage it causes does not notify.
    @ObservationIgnored private var proxyRestarting = false
    /// The redeem request still waiting for a verdict: a retry repeats it under the same key.
    @ObservationIgnored private var resetAttempt: (credit: String?, key: String)?
    /// Claude spend requests still waiting for a verdict, by account and reset.
    @ObservationIgnored private var claudeAttempts: [ResetTarget: String] = [:]
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

    /// `--demo`: made-up accounts and usage instead of TeamClaude and Codex. Nothing is read from
    /// or written to the real setup, and actions change nothing.
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
                await self?.refresh()
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
        readInstalledVersion()
        onChange?()
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
        let env = Shell.environment()
        let wantCodex = force || codexFetchedAt.map { Date().timeIntervalSince($0) > 110 } ?? true

        async let claude = Self.fetchClaude(config: config, env: env)
        async let codex = wantCodex ? Self.fetchCodex(config: config, env: env) : nil
        let (claudeResult, codexResult) = await (claude, codex)
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
                ? config.accounts.keys.sorted().filter { $0 != AppConfig.codexKey }
                    .map { AccountSnapshot.unavailable($0, provider: .claude, error: "Proxy not responding") }
                : previous.map { var account = $0; account.error = "Proxy not responding"; return account }
        }

        if wantCodex {
            codexFetchedAt = stamp
            if var codex = codexResult {
                if codex.error != nil, codex.windows.isEmpty, let last = accounts.first(where: { $0.provider == .codex }) {
                    let message = codex.error
                    codex = last
                    codex.error = message
                }
                merged.append(codex)
            }
        } else if let last = accounts.first(where: { $0.provider == .codex }) {
            merged.append(last)
        }

        accounts = config.ordered(merged)
        readInstalledVersion()
        if let running = proxy.version { installedTeamClaude = teamClaudeOnDisk ?? running }
        now = stamp
        lastRefresh = stamp
        history.record(accounts, now: stamp)
        saveHistoryIfDue()
        evaluateAlerts()
        onChange?()
    }

    private func readInstalledVersion() {
        let version = TeamClaudeUpdates.installedVersion(installDir: config.teamclaudeInstallDir)
        if version != teamClaudeOnDisk { teamClaudeOnDisk = version }
    }

    nonisolated static func fetchClaude(config: AppConfig, env: [String: String]) async
        -> Result<(accounts: [AccountSnapshot], proxy: ProxySnapshot), Error> {
        do {
            let result = try await Shell.run(AppConfig.expand(config.teamclaude), ["status", "--json"],
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
            return try Codex.parse(try await Codex.fetchRateLimits(codex: path, environment: env))
        } catch {
            return .unavailable(AppConfig.codexKey, provider: .codex, error: error.localizedDescription)
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
            accounts: accounts, proxyUp: proxy.up, proxyRestarting: proxyRestarting, latestTeamClaude: latestTeamClaude,
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
        let provider = accounts.first { $0.id == id }?.provider ?? (id == AppConfig.codexKey ? .codex : .claude)
        return config.identity(for: id, provider: provider, index: index)
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

    /// Banked resets across every account.
    var bankedResets: Int { accounts.reduce(0) { $0 + ($1.resets?.available ?? 0) } }

    var updateAvailable: Bool {
        guard let latest = latestTeamClaude, let installed = installedTeamClaude else { return proxy.updateFlag }
        return SemVer.isNewer(latest, than: installed)
    }

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
        let result = try? await Shell.run(AppConfig.expand(config.teamclaude), ["switch", account], timeout: 15)
        flash(result?.status == 0 ? "Routing new requests to \(identity(account).label)" : "Could not switch account")
        await refresh()
    }

    func setProbe(_ seconds: Int) async {
        if refusedInDemo() { return }
        let argument = seconds == 0 ? "off" : String(seconds)
        let result = try? await Shell.run(AppConfig.expand(config.teamclaude), ["probe", argument], timeout: 15)
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
            let outcome = try await Codex.consumeResetCredit(codex: path, environment: Shell.environment(),
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
        let (node, installDir, queue) = (config.node, config.teamclaudeInstallDir, anthropicQueue)
        // A snapshot run does not wait out a rate limit; it falls back to a sample listing.
        let maxWait: TimeInterval? = readOnly ? 0 : nil
        let task = Task {
            do {
                claudeResets[account] = try await queue.run(lane: lane, label: "Read resets: \(identity(account).label)",
                                                            maxWait: maxWait) {
                    try await ClaudeResets.list(node: node, installDir: installDir, account: account,
                                                environment: Shell.environment())
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
        let (node, installDir, queue) = (config.node, config.teamclaudeInstallDir, anthropicQueue)
        let sent = OSAllocatedUnfairLock(initialState: false)
        claudeCalls[lane] = Task {
            var spent = false
            do {
                let verdict = try await queue.run(lane: lane, label: "Spend a reset: \(identity(target.account).label)") {
                    sent.withLock { $0 = true }
                    return try await ClaudeResets.claim(node: node, installDir: installDir, account: target.account,
                                                        grantID: grant, requestID: requestID,
                                                        environment: Shell.environment())
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
            let result = try await Shell.run(AppConfig.expand(config.npm), arguments, timeout: 300)
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
