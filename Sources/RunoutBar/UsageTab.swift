import Charts
import SwiftUI
import RunoutCore

struct UsageTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.summary
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                StatTile(value: summary.claudeLeft.map { Format.percent($0) } ?? "—", label: "Claude pool left",
                         color: Palette.remaining(summary.claudeLeft))
                    .help(poolHelp)
                Button { model.tab = .activity } label: {
                    StatTile(value: "\(model.proxy.activeSessions)", label: "active sessions",
                             detail: "\(model.proxy.knownSessions) known")
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 11))
                .help(sessionsHelp)
                nextLimitTile(summary)
            }
            RunOutCard()
            if model.bankedResets > 0 { ResetsStrip() }
            Card(padding: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weekly pace").sectionTitle()
                        Spacer()
                        Text("above the line burns faster than even").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                    PaceChart().frame(height: 176)
                }
            }
            VStack(spacing: 2) {
                ForEach(model.accounts) { account in
                    AccountRow(account: account)
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

    private func nextLimitTile(_ summary: PoolSummary) -> some View {
        Group {
            if let next = summary.nextLimit {
                let identity = model.identity(next.account)
                let title = model.account(next.account)?.window(next.window)?.title.lowercased() ?? ""
                Button { model.selectedAccount = next.account } label: {
                    StatTile(value: Format.until(next.at, now: model.now),
                             label: "to \(identity.letter) \(title) limit", color: Palette.amber,
                             detail: Format.dayTime(next.at))
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 11))
                .help(nextLimitHelp(next, label: identity.label, title: title))
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

    /// What each Claude account has left, which the tile averages.
    private var poolHelp: String {
        let lines = model.accounts.filter { $0.provider == .claude }.map { account -> String in
            let label = model.identity(account.id).label
            guard !account.isStale(at: model.now), let peak = account.peakWindow, let used = peak.used else {
                return "\(label): no fresh reading"
            }
            return "\(label): \(Format.percent(100 - used)) left "
                + "(\(peak.title.lowercased()) at \(Format.percent(used)))"
        }
        return (["Mean of what is left on each Claude account's fullest window."] + lines).joined(separator: "\n")
    }

    private var sessionsHelp: String {
        let lines = model.accounts.filter { $0.provider == .claude && $0.knownSessions > 0 }.map {
            "\(model.identity($0.id).label): \($0.sessions) active · \($0.knownSessions) known"
        }
        return (lines + ["Click for activity per account."]).joined(separator: "\n")
    }

    private func nextLimitHelp(_ next: (account: String, window: String, at: Date), label: String,
                               title: String) -> String {
        var text = "\(label) reaches its \(title) limit \(Format.dayTime(next.at)) at the current pace"
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

/// When the Claude pool runs out, against the end of the work week. A click opens what the time is built from.
struct RunOutCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage("runOutExpanded") private var expanded = false

    var body: some View {
        if let runOut = model.runOut {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                Card(padding: 9) {
                    VStack(alignment: .leading, spacing: 8) {
                        summary(runOut)
                        if expanded { breakdown(runOut) }
                    }
                }
            }
            .buttonStyle(HoverButtonStyle(cornerRadius: 11))
            .help(help(runOut))
        } else {
            Card(padding: 9) {
                Label("Pool run-out: needs fresh readings and 2 work hours of history", systemImage: "hourglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func help(_ runOut: PoolRunOut) -> String {
        let week: String = model.config.workWeek.summary
        let measured: String = Format.duration(runOut.measuredOver)
        var text: String = "When every Claude account reaches its weekly limit, projected over work hours (\(week)) "
        text += "at the pace measured over the last \(measured) of work. Points are percent of one account's weekly "
        text += "limit; each account's reset adds its capacity back.\n"
        text += expanded ? "Click to hide the detail." : "Click for the detail."
        return text
    }

    private func summary(_ runOut: PoolRunOut) -> some View {
        let color = runOut.state.color
        return HStack(spacing: 9) {
            Image(systemName: runOut.state == .lasts ? "checkmark.circle.fill" : "hourglass")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(runOut)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail(runOut)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(margin(runOut)).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color).lineLimit(1)
                Text("target \(Format.dayTime(runOut.target))").font(.system(size: 10))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
    }

    /// The inputs of the projection: the pace, the pace that would last, the work week and what each account
    /// still holds.
    private func breakdown(_ runOut: PoolRunOut) -> some View {
        let threshold = model.proxy.threshold
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row("Pace", paceText(runOut))
                if let budget = runOut.budgetPerWorkHour {
                    row("Budget", budgetText(budget, target: runOut.target))
                }
                row("Work week", model.config.workWeek.summary)
                ForEach(model.accounts.filter { $0.provider == .claude }) { account in
                    if let weekly = account.weekly, let used = weekly.used {
                        row(model.identity(account.id).label,
                            leftText(used: used, reset: weekly.resetsAt, target: runOut.target))
                    }
                }
            }
            .font(.system(size: 10.5))
            Text("A point is 1% of one account's weekly limit. An account is out at \(Int(threshold))%.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func paceText(_ runOut: PoolRunOut) -> String {
        let rate = String(format: "%.1f", runOut.ratePerWorkHour)
        return "\(rate) pts per work hour over the last \(Format.duration(runOut.measuredOver)) of work"
    }

    private func budgetText(_ budget: Double, target: Date) -> String {
        let rate = String(format: "%.1f", budget)
        return "up to \(rate) pts per work hour reaches \(Format.dayTime(target))"
    }

    /// What an account still holds, and whether its reset adds capacity back before the target.
    private func leftText(used: Double, reset: Date?, target: Date) -> String {
        let left = Int(max(0, model.proxy.threshold - used).rounded())
        var text = "\(left) pts left"
        if let reset {
            text += " · resets \(Format.dayTime(reset))"
            if reset > model.now, reset < target { text += ", before the target" }
        }
        return text
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
        }
    }

    private func headline(_ runOut: PoolRunOut) -> String {
        if let at = runOut.at, at <= model.now { return "Claude pool is out" }
        if let shown = runOut.shownDate(now: model.now) { return "Pool runs out \(Format.dayTime(shown))" }
        return "Pool lasts past \(Format.dayTime(runOut.target))"
    }

    private func margin(_ runOut: PoolRunOut) -> String {
        guard let margin = runOut.margin else { return "lasts" }
        return margin < 0 ? "\(Format.duration(-margin)) short" : "+\(Format.duration(margin))"
    }

    private func detail(_ runOut: PoolRunOut) -> String {
        var text = String(format: "%.1f pts per work hour", runOut.ratePerWorkHour)
        if let budget = runOut.budgetPerWorkHour {
            text += String(format: runOut.state == .lasts ? " · up to %.1f lasts" : " · %.1f would last", budget)
        }
        return text
    }
}

extension PoolRunOut.State {
    var color: Color {
        switch self {
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
                                .help("New requests go to this account")
                        }
                        if let signIn = account.signIn, signIn.stage(at: model.now) > .ok {
                            Pill(text: signInPill(signIn), color: signIn.stage(at: model.now).color, symbol: "key.fill")
                        }
                        Spacer(minLength: 0)
                        Text(subtitle(stale: stale)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    SegmentBar(used: stale ? nil : weekly?.used,
                               even: weekly.flatMap { $0.elapsed(at: model.now) }.map { $0 * 100 },
                               color: stale ? Color.secondary : barColor(weekly, identity))
                    if let fiveHour, !stale {
                        HStack(spacing: 6) {
                            Text("5h").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                            CapsuleBar(used: fiveHour.used, color: barColor(fiveHour, identity).opacity(0.8))
                            Text(Format.percent(fiveHour.used)).font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(fiveHour.tier(full: model.proxy.threshold) == .full
                                                 ? AnyShapeStyle(Palette.red) : AnyShapeStyle(.secondary))
                        }
                    }
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(stale ? "—" : Format.percent(account.peak))
                        .font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(stale ? .secondary : Palette.level(account.peak, full: model.proxy.threshold))
                    // The reset of the window the figure above is for, which is not always the weekly one.
                    Text(Format.until(account.headlineReset(full: model.proxy.threshold), now: model.now))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(width: 46, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
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
    private func barColor(_ window: LimitWindow?, _ identity: AccountIdentity) -> Color {
        switch window?.tier(full: model.proxy.threshold) {
        case .full: return Palette.red
        case .high: return Palette.amber
        default: return Color(hex: identity.color)
        }
    }

    private func subtitle(stale: Bool) -> String {
        if stale {
            if let fetched = account.fetchedAt { return "no fresh reading since \(Format.time(fetched))" }
            return account.error ?? "no reading"
        }
        if account.blocked { return "usage blocked" }
        if let unavailable = account.unavailable { return "out of rotation: \(unavailable)" }
        if account.sessions > 0 { return "\(account.sessions) active session\(account.sessions == 1 ? "" : "s")" }
        if account.isPartial(at: model.now) { return "partial reading" }
        switch account.provider {
        case .codex: return account.plan ?? "Codex"
        case .google: return "Google AI"
        case .claude: return "idle"
        }
    }
}

/// All accounts' weekly windows on one chart: share of the window elapsed
/// against share used. The diagonal is an even pace.
struct PaceChart: View {
    @Environment(AppModel.self) private var model

    struct Point: Identifiable {
        var id: String { "\(series)-\(x)" }
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
        var label: String
        var start: Date
        var duration: TimeInterval
        /// The readings and the projection as one line, for the readout under the pointer.
        var path: [Series.Point] { (trail + projection.dropFirst()).map { Series.Point(x: $0.x, y: $0.y) } }
    }

    /// The account whose line is under the pointer; the others dim.
    @State private var hovered: String?

    private var lines: [Line] {
        model.accounts.compactMap { account in
            guard !account.isStale(at: model.now), let weekly = account.weekly, let used = weekly.used,
                  let start = weekly.windowStart, let duration = weekly.duration,
                  let elapsed = weekly.elapsed(at: model.now) else { return nil }
            let identity = model.identity(account.id)
            // The current reading is appended below; the sample recorded at this instant would duplicate it.
            let samples = model.history.samples(account.id).filter { $0.time >= start && $0.time < model.now }
            var trail = samples.compactMap { sample -> Point? in
                guard let value = sample.values[weekly.id] else { return nil }
                return Point(series: account.id, x: sample.time.timeIntervalSince(start) / duration * 100, y: value)
            }
            if trail.count > 160 {
                let stride = trail.count / 160 + 1
                trail = trail.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            }
            let current = Point(series: account.id, x: elapsed * 100, y: used)
            trail.append(current)
            // The window starts at 0%; history may not reach back that far yet.
            let leadIn = trail.first.map { $0.x > 2 ? [Point(series: account.id + ".l", x: 0, y: 0), $0] : [] } ?? []
            var projection: [Point] = []
            var hits = false
            if let pace = model.pace(account, weekly) {
                if let fullAt = pace.fullAt {
                    hits = true
                    projection = [current, Point(series: account.id + ".p", x: fullAt.timeIntervalSince(start) / duration * 100,
                                                 y: model.proxy.threshold)]
                } else if pace.atReset > used + 0.5 {
                    projection = [current, Point(series: account.id + ".p", x: 100, y: pace.atReset)]
                }
            }
            return Line(id: account.id, color: Color(hex: identity.color), letter: identity.letter, trail: trail,
                        leadIn: leadIn, now: current, projection: projection, hitsLimit: hits, label: identity.label,
                        start: start, duration: duration)
        }
    }

    var body: some View {
        let lines = lines
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
            RuleMark(y: .value("Limit", model.proxy.threshold))
                .foregroundStyle(Palette.red.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))

            ForEach(lines) { line in
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
                        .foregroundStyle(line.hitsLimit ? Palette.amber : line.color.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .opacity(strength(line))
                }
                if line.hitsLimit, let end = line.projection.last {
                    PointMark(x: .value("Elapsed", end.x), y: .value("Used", end.y))
                        .foregroundStyle(Palette.amber)
                        .symbolSize(22)
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
    }

    private func strength(_ line: Line) -> Double { hovered == nil || hovered == line.id ? 1 : 0.25 }

    /// The line nearest the pointer, read at the pointer's share of the window.
    private func readout(_ lines: [Line], x: Double, y: Double) -> ChartReadout<Double>? {
        guard let hit = Series.closest(lines.map(\.path), x: x, y: y, reach: 14) else { return nil }
        let line = lines[hit.index]
        let time = line.start.addingTimeInterval(line.duration * x / 100)
        let kind = x > line.now.x ? "projected" : "used"
        let reading = "\(Format.dayTime(time)) · \(Format.percent(hit.y)) \(kind)"
        let rows: [ChartReadout<Double>.Row] = [.init(color: line.color, text: reading),
                                                .init(text: "even pace \(Format.percent(x))")]
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
