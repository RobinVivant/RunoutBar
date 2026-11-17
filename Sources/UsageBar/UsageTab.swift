import Charts
import SwiftUI
import UsageCore

struct UsageTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.summary
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                StatTile(value: summary.claudeLeft.map { Format.percent($0) } ?? "—", label: "Claude pool left",
                         color: Palette.remaining(summary.claudeLeft))
                StatTile(value: "\(model.proxy.activeSessions)", label: "active sessions",
                         detail: "\(model.proxy.knownSessions) known")
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
            ForEach(expiringCallouts, id: \.self) { text in
                Callout(symbol: "hourglass", color: Palette.amber, text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func nextLimitTile(_ summary: PoolSummary) -> some View {
        Group {
            if let next = summary.nextLimit {
                let identity = model.identity(next.account)
                let title = model.account(next.account)?.window(next.window)?.title.lowercased() ?? ""
                StatTile(value: Format.until(next.at, now: model.now), label: "to \(identity.letter) \(title) limit",
                         color: Palette.amber, detail: Format.dayTime(next.at))
            } else {
                StatTile(value: "None", label: "limit before reset", color: Palette.ok, detail: "at the current pace")
            }
        }
    }

    /// Weekly allowance about to expire unused: less than 36 h left and under 85%.
    private var expiringCallouts: [String] {
        model.accounts.compactMap { account in
            guard !account.isStale(at: model.now), let weekly = account.weekly, let used = weekly.used,
                  let reset = weekly.resetsAt else { return nil }
            let left = reset.timeIntervalSince(model.now)
            guard left > 0, left < 36 * 3600, used < 85 else { return nil }
            return "\(model.identity(account.id).label): \(Int((100 - used).rounded()))% of this week unused, "
                + "expires in \(Format.duration(left))"
        }
    }
}

/// When the Claude pool runs out, against the end of the work week.
struct RunOutCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(padding: 9) {
            if let runOut = model.runOut {
                let color = runOut.state.color
                HStack(spacing: 9) {
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
                }
                .help("When every Claude account reaches its weekly limit, projected over work hours "
                    + "(\(model.config.workWeek.summary)) at the pace measured over the last "
                    + "\(Format.duration(runOut.measuredOver)) of work. Points are percent of one account's weekly "
                    + "limit; each account's reset adds its capacity back.")
            } else {
                Label("Pool run-out: needs fresh readings and 2 work hours of history", systemImage: "hourglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
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
    @State private var hovering = false

    var body: some View {
        let identity = model.identity(account.id)
        let stale = account.isStale(at: model.now)
        let weekly = account.weekly
        let fiveHour = account.window("5h")
        let color = stale ? Color.secondary : tierColor(identity)
        Button {
            model.selectedAccount = account.id
        } label: {
            HStack(spacing: 10) {
                Badge(identity: identity, size: 24).opacity(stale ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(identity.label).font(.system(size: 12.5, weight: .semibold))
                        if account.routing { Pill(text: "routing", color: Palette.ok, symbol: "arrow.triangle.branch") }
                        Spacer(minLength: 0)
                        Text(subtitle(stale: stale)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    SegmentBar(used: stale ? nil : weekly?.used,
                               even: weekly.flatMap { $0.elapsed(at: model.now) }.map { $0 * 100 }, color: color)
                    if let fiveHour, !stale {
                        HStack(spacing: 6) {
                            Text("5h").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                            CapsuleBar(used: fiveHour.used, color: Color(hex: identity.color).opacity(0.8))
                            Text(Format.percent(fiveHour.used)).font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(stale ? "—" : Format.percent(account.peak))
                        .font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(stale ? .secondary : Palette.level(account.peak, full: model.proxy.threshold))
                    Text(Format.until(weekly?.resetsAt, now: model.now))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(width: 46, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(hovering ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func tierColor(_ identity: AccountIdentity) -> Color {
        switch account.tier(at: model.now, full: model.proxy.threshold) {
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
        return account.provider == .codex ? (account.plan ?? "Codex") : "idle"
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
    }

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
                        leadIn: leadIn, now: current, projection: projection, hitsLimit: hits)
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
                }
                ForEach(line.trail) { point in
                    LineMark(x: .value("Elapsed", point.x), y: .value("Used", point.y),
                             series: .value("Series", line.id))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                ForEach(line.projection) { point in
                    LineMark(x: .value("Elapsed", point.x), y: .value("Used", point.y),
                             series: .value("Series", line.id + ".projection"))
                        .foregroundStyle(line.hitsLimit ? Palette.amber : line.color.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                if line.hitsLimit, let end = line.projection.last {
                    PointMark(x: .value("Elapsed", end.x), y: .value("Used", end.y))
                        .foregroundStyle(Palette.amber)
                        .symbolSize(22)
                }
                PointMark(x: .value("Elapsed", line.now.x), y: .value("Used", line.now.y))
                    .foregroundStyle(line.color)
                    .symbolSize(70)
                    .annotation(position: .trailing, spacing: 3) {
                        Text(line.letter).font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(line.color)
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
        .overlay {
            if lines.isEmpty {
                Text("No fresh weekly readings").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
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
