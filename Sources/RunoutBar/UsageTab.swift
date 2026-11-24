import Charts
import SwiftUI
import RunoutCore

struct UsageTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.summary
        let showsSessions = model.accounts.contains { $0.provider == .claude || $0.provider == .google }
            || model.activeSessions > 0 || model.knownSessions > 0
        VStack(spacing: 10) {
            if !model.accounts.isEmpty {
                if showsSessions {
                    HStack(spacing: 8) {
                        sessionsTile
                        nextLimitTile(summary)
                    }
                } else {
                    nextLimitTile(summary)
                }
            }
            if !model.lanes.isEmpty { RunwayCard() }
            if model.bankedResets > 0 { ResetsStrip() }
            Card(padding: 8) {
                PaceChart()
            }
            VStack(spacing: 8) {
                ForEach(model.providerSections) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader(section)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 1)
                        ForEach(section.accounts) { account in
                            AccountRow(account: account)
                        }
                    }
                }
            }
            ForEach(expiringCallouts, id: \.account) { expiring in
                Button { model.selectedAccount = expiring.account } label: {
                    Callout(symbol: "hourglass", color: Palette.amber, text: expiring.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3).padding(.horizontal, 8)
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 7))
                .help("Open the account")
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ section: ProviderSection) -> some View {
        HStack(spacing: 6) {
            Text(sectionTitle(section.provider))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.3)
            Spacer(minLength: 0)
            Text(sectionDetail(section))
                .font(.system(size: 9.5))
                .foregroundStyle(sectionDetailColor(section.provider))
                .lineLimit(1)
        }
    }

    private func sectionTitle(_ provider: Provider) -> String {
        switch provider {
        case .claude: return "ANTHROPIC · TEAMCLAUDE POOL"
        case .codex: return "OPENAI · CODEX"
        case .google: return "GOOGLE AI · ANTIGRAVITY"
        }
    }

    private func sectionDetail(_ section: ProviderSection) -> String {
        switch section.provider {
        case .claude:
            if !model.proxy.up { return "Proxy down" }
            let routed = section.accounts.first(where: \.routing).map { "Routing → \(model.identity($0.id).label)" }
            let left = model.lanes.first { $0.provider == .claude }?.weeklyLeft(at: model.now)
                .map { "\(Int($0.rounded()))% wk left" }
            return [routed, left].compactMap { $0 }.joined(separator: " · ")
        case .codex:
            return [section.accounts.first?.plan, "Direct CLI"].compactMap { $0 }.joined(separator: " · ")
        case .google:
            let active = model.googleActiveSessions
            return [active > 0 ? "\(active) active" : nil, "Direct CLI"].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func sectionDetailColor(_ provider: Provider) -> Color {
        provider == .claude && !model.proxy.up ? Palette.red : .secondary
    }

    private func nextLimitTile(_ summary: PoolSummary) -> some View {
        Group {
            if let next = summary.nextLimit {
                let identity = model.identity(next.account)
                let title = model.account(next.account)?.window(next.window)?.title.lowercased() ?? ""
                let shortTitle = shortWindowLabel(title)
                Button { model.selectedAccount = next.account } label: {
                    StatTile(value: Format.until(next.at, now: model.now),
                             label: "\(identity.label) \(shortTitle) wall", color: Palette.amber,
                             detail: Format.dayTime(next.at))
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 11))
                .help(nextLimitHelp(next, label: identity.label, title: title, isSwitch: false))
            } else if let rot = summary.nextRotation {
                let identity = model.identity(rot.account)
                let title = model.account(rot.account)?.window(rot.window)?.title.lowercased() ?? ""
                Button { model.selectedAccount = rot.account } label: {
                    StatTile(value: "No wall",
                             label: "switches in \(Format.until(rot.at, now: model.now))", color: Palette.ok,
                             detail: "\(identity.label) rotates in pool")
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 11))
                .help(nextLimitHelp(rot, label: identity.label, title: title, isSwitch: true))
            } else if model.accounts.contains(where: { !$0.isStale(at: model.now) }) {
                StatTile(value: "None", label: "limit before reset", color: Palette.ok, detail: "at the current pace")
                    .help("At the current pace no window reaches its limit before it resets.")
            } else {
                // Without a fresh reading there is no pace to project.
                StatTile(value: "—", label: "limit before reset")
                    .help("No fresh reading to project from.")
            }
        }
    }

    private func shortWindowLabel(_ title: String) -> String {
        if title == "5-hour" { return "5h" }
        if title == "weekly" { return "7d" }
        if title.hasSuffix(" weekly") { return String(title.dropLast(7)) }
        return title
    }

    private var sessionsTile: some View {
        let claude = model.claudeActiveSessions
        let google = model.googleActiveSessions
        let breakdown = [claude > 0 ? "\(claude) Claude" : nil, google > 0 ? "\(google) Google" : nil]
            .compactMap { $0 }
        let detail = breakdown.isEmpty ? "\(model.knownSessions) known" : breakdown.joined(separator: " · ")
        return Button { model.tab = .activity } label: {
            StatTile(value: "\(model.activeSessions)", label: "active sessions", detail: detail)
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 11))
        .help(sessionsHelp)
    }

    private var sessionsHelp: String {
        var lines = model.accounts.filter { $0.provider == .claude && ($0.sessions > 0 || $0.knownSessions > 0) }.map {
            "\(model.identity($0.id).label): \($0.sessions) active · \($0.knownSessions) known"
        }
        if model.googleActiveSessions > 0 || model.googleKnownSessions > 0 {
            lines.append("Google AI (Antigravity): \(model.googleActiveSessions) active · \(model.googleKnownSessions) known")
        }
        if model.accounts.contains(where: { $0.provider == .codex }) {
            lines.append("Codex CLI does not report sessions.")
        }
        return (lines + ["Click for activity per account."]).joined(separator: "\n")
    }

    private func nextLimitHelp(_ next: (account: String, window: String, at: Date), label: String,
                               title: String, isSwitch: Bool) -> String {
        var text = isSwitch
            ? "\(label) reaches its \(title) switch threshold \(Format.dayTime(next.at)) and rotates within TeamClaude"
            : "\(label) reaches its \(title) limit \(Format.dayTime(next.at)) at the current pace"
        if let account = model.account(next.account), let window = account.window(next.window),
           let pace = model.pace(account, window), let rate = pace.ratePerHour {
            text += String(format: " (%.1f%%/h", rate) + (pace.basis.map { ", \($0.rawValue)" } ?? "") + ")"
        }
        return text + ".\nClick to open the account."
    }

    /// Weekly allowance about to expire unused: less than 36 h left and under 85%.
    private var expiringCallouts: [(account: String, text: String)] {
        model.accounts.compactMap { account in
            guard !account.isStale(at: model.now), let weekly = account.weekly, let used = weekly.used,
                  let reset = weekly.resetsAt else { return nil }
            let left = reset.timeIntervalSince(model.now)
            guard left > 0, left < 36 * 3600, used < 85 else { return nil }
            return (account.id, "\(model.identity(account.id).label): \(Int((100 - used).rounded()))% of this week "
                + "unused, expires in \(Format.duration(left))")
        }
    }
}

/// Work-week run-out across every capacity lane (Claude pool, Codex, and Google AI groups).
/// Click any lane row to expand its pace, budget, and capacity breakdown.
struct RunwayCard: View {
    @Environment(AppModel.self) private var model
    @State private var expandedLane: String?

    var body: some View {
        let global = model.globalRunOut
        Card(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Work-week runway").sectionTitle()
                    if let target = global.target {
                        Text("target \(Format.dayTime(target))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    verdict(global)
                }
                Divider()
                VStack(spacing: 2) {
                    ForEach(global.lanes) { entry in
                        laneBlock(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func verdict(_ global: GlobalRunOut) -> some View {
        switch global.state {
        case .critical:
            let outNow = global.bottleneck?.runOut?.at.map { $0 <= model.now } ?? false
            Pill(text: outNow ? "out" : "\(global.shortCount) critical", color: Palette.red)
        case .short:
            Pill(text: "\(global.shortCount) short", color: Palette.amber)
        case .lasts:
            Pill(text: "all last", color: Palette.ok, symbol: "checkmark")
        case .idle:
            Text("idle").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func laneBlock(_ entry: LaneRunOut) -> some View {
        let lane = entry.lane
        let open = expandedLane == entry.id
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    expandedLane = open ? nil : entry.id
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(laneColor(lane)).frame(width: 7, height: 7)
                    Text(lane.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if lane.kind.isPooled {
                        Text("pool · \(lane.accounts.count)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    Text(entry.weeklyLeft.map { "\(Int($0.rounded()))% left" } ?? "—")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ratioView(entry.runOut)
                        .frame(width: 32, alignment: .trailing)
                    statusView(entry)
                        .frame(width: 60, alignment: .trailing)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.vertical, 3.5)
                .padding(.horizontal, 5)
            }
            .buttonStyle(HoverButtonStyle(cornerRadius: 7))
            .help(laneHelp(entry))

            if open {
                breakdown(entry)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func ratioView(_ runOut: PoolRunOut?) -> some View {
        if let runOut, runOut.state != .idle, let ratio = runOut.paceRatio {
            let color: Color = runOut.state == .critical ? Palette.red
                : (runOut.state == .short || ratio > 1.0) ? Palette.amber : .secondary
            Text(String(format: "%.1f×", ratio))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        } else {
            Text("—")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func statusView(_ entry: LaneRunOut) -> some View {
        if let runOut = entry.runOut {
            switch runOut.state {
            case .idle:
                Text("idle").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            case .lasts:
                let label = runOut.shownDate(now: model.now).map { Format.dayTime($0) } ?? "✓ lasts"
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ok)
                    .lineLimit(1)
            case .short, .critical:
                let label = runOut.at.map { $0 <= model.now ? "out" : Format.dayTime($0) } ?? "short"
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(runOut.state.color)
                    .lineLimit(1)
            }
        } else if entry.lane.accounts.contains(where: { $0.isStale(at: model.now) || $0.error != nil }) {
            Text("stale").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        } else {
            Text("…").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func breakdown(_ entry: LaneRunOut) -> some View {
        let lane = entry.lane
        let unit = lane.kind.isPooled && lane.accounts.count > 1 ? "pts" : "%"
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            if let r = entry.runOut {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3.5) {
                    row("Pace", paceText(r, unit: unit))
                    if let budget = r.budgetPerWorkHour {
                        row("Budget", budgetText(budget, unit: unit, target: r.target))
                    }
                    row("Work week", model.config.workWeek.summary)
                    ForEach(lane.accounts) { account in
                        if let weekly = account.weekly, let used = weekly.used {
                            row(model.identity(account.id).label,
                                leftText(used: used, threshold: lane.threshold, reset: weekly.resetsAt,
                                         target: r.target, unit: unit))
                        }
                    }
                }
                .font(.system(size: 10.5))
                if entry.bankedResets > 0 {
                    Text("\(entry.bankedResets) banked reset\(entry.bankedResets == 1 ? "" : "s") held in reserve")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if lane.kind.isPooled {
                    Text("A point is 1% of one account's weekly limit. Switches at \(Int(lane.threshold))%.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if let only = lane.accounts.first {
                    Button("Open \(lane.title)") { model.selectedAccount = only.id }
                        .buttonStyle(LinkButtonStyle())
                        .font(.system(size: 10, weight: .medium))
                }
            } else {
                Label("Needs fresh weekly readings and 2 work hours of history", systemImage: "hourglass")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func paceText(_ r: PoolRunOut, unit: String) -> String {
        if r.state == .idle {
            return r.measuredOver > 0
                ? "idle over the last \(Format.duration(r.measuredOver)) of work"
                : "untouched (starts on first use)"
        }
        let rate = String(format: "%.1f", r.ratePerWorkHour)
        var text = "\(rate) \(unit)/work h (\(r.paceBasis.rawValue)"
        if r.measuredOver > 0 { text += " · \(Format.duration(r.measuredOver))" }
        text += ")"
        if r.quietToday { text += " · quiet today" }
        return text
    }

    private func budgetText(_ budget: Double, unit: String, target: Date) -> String {
        let rate = String(format: "%.1f", budget)
        return "up to \(rate) \(unit)/work h reaches \(Format.dayTime(target))"
    }

    private func leftText(used: Double, threshold: Double, reset: Date?, target: Date, unit: String) -> String {
        let left = Int(max(0, threshold - used).rounded())
        var text = "\(left) \(unit == "pts" ? "pts" : "%") left"
        if let reset {
            text += " · resets \(Format.dayTime(reset))"
            if reset > model.now, reset < target { text += ", before the target" }
        } else if used == 0 {
            text += " · starts on first use"
        }
        return text
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func laneColor(_ lane: CapacityLane) -> Color {
        if lane.provider == .claude {
            let active = lane.accounts.first(where: \.routing) ?? lane.accounts.first
            return Color(hex: active.map { model.identity($0.id).color } ?? AppConfig.palette[0])
        }
        return Color(hex: lane.accounts.first.map { model.identity($0.id).color } ?? AppConfig.palette[0])
    }

    private func laneHelp(_ entry: LaneRunOut) -> String {
        let name = entry.lane.provider == .claude ? "Claude pool" : entry.lane.title
        if let r = entry.runOut {
            return model.runOutSentence(r, laneTitle: name) + "\nClick for pace and budget breakdown."
        }
        return "\(name): needs fresh weekly readings and 2 work hours of history."
    }
}

extension PoolRunOut.State {
    var color: Color {
        switch self {
        case .idle: return .secondary
        case .lasts: return Palette.ok
        case .short: return Palette.amber
        case .critical: return Palette.red
        }
    }
}

struct AccountRow: View {
    @Environment(AppModel.self) private var model
    var account: AccountSnapshot

    var body: some View {
        let identity = model.identity(account.id)
        let stale = account.isStale(at: model.now)
        let threshold = account.effectiveThreshold(proxyThreshold: model.proxy.threshold)
        let weekly = account.weekly
        let fiveHour = account.window("5h")
        Button {
            model.selectedAccount = account.id
        } label: {
            HStack(spacing: 10) {
                Badge(identity: identity, size: 24).opacity(stale ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(identity.label).font(.system(size: 12.5, weight: .semibold))
                        if account.routing {
                            Pill(text: "routing", color: Palette.ok, symbol: "arrow.triangle.branch")
                                .help("New Claude requests go to this account")
                        }
                        if let signIn = account.signIn, signIn.stage(at: model.now) > .ok {
                            Pill(text: signInPill(signIn), color: signIn.stage(at: model.now).color, symbol: "key.fill")
                        }
                        Spacer(minLength: 0)
                        Text(subtitle(stale: stale)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    SegmentBar(used: stale ? nil : weekly?.used,
                               even: weekly.flatMap { $0.elapsed(at: model.now) }.map { $0 * 100 },
                               color: stale ? Color.secondary : barColor(weekly, identity, threshold: threshold))
                    if let fiveHour, !stale {
                        HStack(spacing: 6) {
                            Text("5h").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                            CapsuleBar(used: fiveHour.used,
                                       color: barColor(fiveHour, identity, threshold: threshold).opacity(0.8))
                            Text(Format.percent(fiveHour.used)).font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(fiveHour.tier(full: threshold) == .full
                                                 ? AnyShapeStyle(Palette.red) : AnyShapeStyle(.secondary))
                        }
                    }
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(stale ? "—" : Format.percent(account.peak))
                        .font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(stale ? .secondary : Palette.level(account.peak, full: threshold))
                    // The reset of the window the figure above is for, which is not always the weekly one.
                    Text(Format.until(account.headlineReset(full: threshold), now: model.now))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(width: 46, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6.5)
            .padding(.horizontal, 8)
        }
        .buttonStyle(HoverButtonStyle())
        .help(model.windowsSummary(account))
    }

    /// "sign-in 18h" while it counts down, "sign in" once it has stopped.
    private func signInPill(_ signIn: SignIn) -> String {
        guard signIn.failure == nil, let end = signIn.expiresAt, end > model.now else { return "sign in" }
        return "sign-in \(Format.duration(end.timeIntervalSince(model.now)))"
    }

    /// A bar takes the level of the window it draws, not of the account: after a banked reset the weekly
    /// bar is low again and must not stay red because the session window filled.
    private func barColor(_ window: LimitWindow?, _ identity: AccountIdentity, threshold: Double) -> Color {
        switch window?.tier(full: threshold) {
        case .full: return Palette.red
        case .high: return Palette.amber
        default: return Color(hex: identity.color)
        }
    }

    private func subtitle(stale: Bool) -> String {
        if stale {
            if let fetched = account.fetchedAt { return "no fresh reading since \(Format.time(fetched))" }
            if account.signIn?.failure?.code == "signed_out" { return "not signed in" }
            return account.error ?? "no reading"
        }
        if account.blocked { return "usage blocked" }
        if let unavailable = account.unavailable { return "out of rotation: \(unavailable)" }
        if account.provider == .claude, account.sessions > 0 {
            return "\(account.sessions) active session\(account.sessions == 1 ? "" : "s")"
        }
        if account.isPartial(at: model.now) { return "partial reading" }
        switch account.provider {
        case .codex: return account.plan ?? "Direct CLI"
        case .google:
            if let covers = account.covers {
                let count = covers.split(separator: ",").count
                return count > 1 ? "\(count) models" : covers
            }
            return "Google AI"
        case .claude: return "idle"
        }
    }
}

/// All accounts' weekly windows on one chart: share of the window elapsed
/// against share used. The diagonal is an even pace.
struct PaceChart: View {
    @Environment(AppModel.self) private var model

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", claude = "Claude", direct = "Direct"
        var id: String { rawValue }
    }

    struct Point: Identifiable {
        var id: String
        var series: String
        var x: Double
        var y: Double
    }

    struct Line: Identifiable {
        var id: String
        var color: Color
        var letter: String
        var trail: [Point]
        var leadIn: [Point]
        var now: Point
        var projection: [Point]
        var hitsLimit: Bool
        var isPoolSwitch: Bool
        var threshold: Double
        var label: String
        var start: Date
        var duration: TimeInterval
        /// The readings and the projection as one line, for the readout under the pointer.
        var path: [Series.Point] { (trail + projection.dropFirst()).map { Series.Point(x: $0.x, y: $0.y) } }
    }

    /// The account whose line is under the pointer; the others dim.
    @State private var hovered: String?
    @State private var scope: Scope = .all

    private var hasMixedSources: Bool {
        model.accounts.contains { $0.provider == .claude } && model.accounts.contains { $0.provider != .claude }
    }

    private var filteredAccounts: [AccountSnapshot] {
        guard hasMixedSources else { return model.accounts }
        switch scope {
        case .all: return model.accounts
        case .claude: return model.accounts.filter { $0.provider == .claude }
        case .direct: return model.accounts.filter { $0.provider != .claude }
        }
    }

    private var limitRule: Double {
        if hasMixedSources && scope == .direct { return 100 }
        return model.accounts.contains { $0.provider == .claude } ? model.proxy.threshold : 100
    }

    private var lines: [Line] {
        filteredAccounts.compactMap { account in
            guard !account.isStale(at: model.now), let weekly = account.weekly, let used = weekly.used,
                  let start = weekly.windowStart, let duration = weekly.duration,
                  let elapsed = weekly.elapsed(at: model.now) else { return nil }
            let identity = model.identity(account.id)
            let threshold = account.effectiveThreshold(proxyThreshold: model.proxy.threshold)
            // The current reading is appended below; the sample recorded at this instant would duplicate it.
            let samples = model.history.samples(account.id).filter { $0.time >= start && $0.time < model.now }
            var raw = samples.compactMap { sample -> Series.Point? in
                guard let value = sample.values[weekly.id] else { return nil }
                return Series.Point(x: sample.time.timeIntervalSince(start) / duration * 100, y: value)
            }
            if raw.count > 160 {
                let stride = raw.count / 160 + 1
                raw = raw.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            }
            let currentX = elapsed * 100
            raw.append(Series.Point(x: currentX, y: used))
            let trimmed = Series.sinceLastReset(raw)
            let trail = trimmed.points.enumerated().map {
                Point(id: "\(account.id)-\($0.offset)", series: account.id, x: $0.element.x, y: $0.element.y)
            }
            let current = trail.last ?? Point(id: "\(account.id)-now", series: account.id, x: currentX, y: used)
            // The window starts at 0%; history may not reach back that far yet, unless trimmed to a banked reset.
            let leadIn = !trimmed.reset
                ? (trail.first.map {
                    $0.x > 2 ? [Point(id: "\(account.id)-l0", series: account.id + ".l", x: 0, y: 0),
                                Point(id: "\(account.id)-l1", series: account.id + ".l", x: $0.x, y: $0.y)] : []
                } ?? [])
                : []
            var projection: [Point] = []
            var hits = false
            let canRotate = account.provider == .claude
                && (model.lane(for: account.id)?.hasHeadroom(excluding: account.id, at: model.now) ?? false)
            if let pace = model.pace(account, weekly) {
                let p0 = Point(id: "\(account.id)-p0", series: account.id + ".p", x: current.x, y: current.y)
                if let fullAt = pace.fullAt {
                    hits = true
                    projection = [p0, Point(id: "\(account.id)-p1", series: account.id + ".p",
                                            x: fullAt.timeIntervalSince(start) / duration * 100,
                                            y: threshold)]
                } else if pace.atReset > used + 0.5 {
                    projection = [p0, Point(id: "\(account.id)-p1", series: account.id + ".p", x: 100, y: pace.atReset)]
                }
            }
            return Line(id: account.id, color: Color(hex: identity.color), letter: identity.letter, trail: trail,
                        leadIn: leadIn, now: current, projection: projection, hitsLimit: hits,
                        isPoolSwitch: hits && canRotate, threshold: threshold, label: identity.label,
                        start: start, duration: duration)
        }
    }

    var body: some View {
        let lines = lines
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Weekly pace").sectionTitle()
                Spacer()
                if hasMixedSources {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 138).controlSize(.mini)
                } else {
                    Text("above the line burns faster than even").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
            Chart {
                AreaMark(x: .value("Elapsed", 0), yStart: .value("Even", 0), yEnd: .value("Top", 100))
                    .foregroundStyle(Palette.amber.opacity(0.07))
                AreaMark(x: .value("Elapsed", 100), yStart: .value("Even", 100), yEnd: .value("Top", 100))
                    .foregroundStyle(Palette.amber.opacity(0.07))
                LineMark(x: .value("Elapsed", 0), y: .value("Used", 0), series: .value("Series", "even"))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                LineMark(x: .value("Elapsed", 100), y: .value("Used", 100), series: .value("Series", "even"))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RuleMark(y: .value("Limit", limitRule))
                    .foregroundStyle(Palette.red.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))

                ForEach(lines) { line in
                    let wallAlert = line.hitsLimit && !line.isPoolSwitch
                    ForEach(line.leadIn) { point in
                        LineMark(x: .value("Elapsed", point.x), y: .value("Used", point.y),
                                 series: .value("Series", line.id + ".lead-in"))
                            .foregroundStyle(line.color.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [1, 3]))
                            .opacity(strength(line))
                    }
                    ForEach(line.trail) { point in
                        LineMark(x: .value("Elapsed", point.x), y: .value("Used", point.y),
                                 series: .value("Series", line.id))
                            .foregroundStyle(line.color)
                            .lineStyle(StrokeStyle(lineWidth: hovered == line.id ? 3 : 2, lineCap: .round,
                                                   lineJoin: .round))
                            .interpolationMethod(.monotone)
                            .opacity(strength(line))
                    }
                    ForEach(line.projection) { point in
                        LineMark(x: .value("Elapsed", point.x), y: .value("Used", point.y),
                                 series: .value("Series", line.id + ".projection"))
                            .foregroundStyle(wallAlert ? Palette.amber : line.color.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .opacity(strength(line))
                    }
                    if line.hitsLimit, let end = line.projection.last {
                        PointMark(x: .value("Elapsed", end.x), y: .value("Used", end.y))
                            .foregroundStyle(wallAlert ? Palette.amber : line.color.opacity(0.7))
                            .symbolSize(wallAlert ? 22 : 14)
                            .opacity(strength(line))
                    }
                    PointMark(x: .value("Elapsed", line.now.x), y: .value("Used", line.now.y))
                        .foregroundStyle(line.color)
                        .symbolSize(70)
                        .opacity(strength(line))
                        .annotation(position: .trailing, spacing: 3) {
                            Text(line.letter).font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(line.color).opacity(strength(line))
                        }
                }
            }
            .chartXScale(domain: 0...100)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel(anchor: anchor(value.as(Double.self))) {
                        Text(axisLabel(value.as(Double.self))).font(.system(size: 9))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)").font(.system(size: 9)) }
                }
            }
            .chartLegend(.hidden)
            .chartReadout(subject: $hovered, onTap: { model.selectedAccount = $0.subject }) { (x: Double, y: Double) in
                readout(lines, x: x, y: y)
            }
            .overlay {
                if lines.isEmpty {
                    Text("No fresh weekly readings").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 152)
        }
    }

    private func strength(_ line: Line) -> Double { hovered == nil || hovered == line.id ? 1 : 0.25 }

    /// The line nearest the pointer, read at the pointer's share of the window.
    private func readout(_ lines: [Line], x: Double, y: Double) -> ChartReadout<Double>? {
        guard let hit = Series.closest(lines.map(\.path), x: x, y: y, reach: 14) else { return nil }
        let line = lines[hit.index]
        let time = line.start.addingTimeInterval(line.duration * x / 100)
        let kind = x > line.now.x ? "projected" : "used"
        let reading = "\(Format.dayTime(time)) · \(Format.percent(hit.y)) \(kind)"
        var rows: [ChartReadout<Double>.Row] = [.init(color: line.color, text: reading),
                                                .init(text: "even pace \(Format.percent(x))")]
        if x > line.now.x, line.isPoolSwitch {
            rows.append(.init(text: "pool rotates at \(Int(line.threshold))%"))
        }
        return ChartReadout(x: x, dots: [.init(y: hit.y, color: line.color)], title: line.label, rows: rows,
                            subject: line.id)
    }

    private func axisLabel(_ value: Double?) -> String {
        switch value {
        case 0: return "window start"
        case 100: return "reset"
        default: return "halfway"
        }
    }

    private func anchor(_ value: Double?) -> UnitPoint {
        switch value {
        case 0: return .topLeading
        case 100: return .topTrailing
        default: return .top
        }
    }
}
