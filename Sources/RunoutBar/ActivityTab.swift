import Charts
import SwiftUI
import RunoutCore

struct ActivityTab: View {
    @Environment(AppModel.self) private var model
    @State private var range: Range = .day
    @State private var scope: Scope = .all
    /// The account under the pointer in the legend; the other lines dim.
    @State private var highlighted: String?
    /// The token kind under the pointer.
    @State private var hoveredTokens: String?

    enum Range: String, CaseIterable, Identifiable {
        case sixHours = "6 h", day = "24 h", week = "7 d"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .sixHours: return 6 * 3600
            case .day: return 86_400
            case .week: return 7 * 86_400
            }
        }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", claude = "Claude", direct = "Direct"
        var id: String { rawValue }
    }

    struct Point: Identifiable {
        var id: String { "\(account)-\(time.timeIntervalSince1970)" }
        var account: String
        var time: Date
        var value: Double
    }

    private var hasMixedSources: Bool {
        model.accounts.contains { $0.provider == .claude } && model.accounts.contains { $0.provider != .claude }
    }

    private var visibleAccounts: [AccountSnapshot] {
        guard hasMixedSources else { return model.accounts }
        switch scope {
        case .all: return model.accounts
        case .claude: return model.accounts.filter { $0.provider == .claude }
        case .direct: return model.accounts.filter { $0.provider != .claude }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Weekly usage").sectionTitle()
                        Spacer()
                        if hasMixedSources {
                            Picker("Source", selection: $scope) {
                                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 122).controlSize(.mini)
                        }
                        Picker("Range", selection: $range) {
                            ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 130).controlSize(.mini)
                    }
                    historyChart.frame(height: 130).padding(.trailing, 10)
                    legend
                }
            }
            VStack(spacing: 8) {
                ForEach(model.providerSections) { section in
                    let rows = section.accounts.filter { visibleAccounts.contains($0) }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            sectionHeader(section).padding(.horizontal, 4)
                            ForEach(rows) { account in
                                activityRow(account)
                            }
                        }
                    }
                }
            }
            if let tokens = model.proxy.tokens, tokens.total > 0 {
                tokenCard(tokens)
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ section: ProviderSection) -> some View {
        HStack {
            Text(sectionTitle(section.provider))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.3)
            Spacer()
            if section.provider == .google, model.googleActiveSessions > 0 || model.googleKnownSessions > 0 {
                Text("\(model.googleActiveSessions) active · \(model.googleKnownSessions) known")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionTitle(_ provider: Provider) -> String {
        switch provider {
        case .claude: return "ANTHROPIC · TEAMCLAUDE POOL"
        case .codex: return "OPENAI · CODEX"
        case .google: return "GOOGLE AI · ANTIGRAVITY"
        }
    }

    private var points: [Point] {
        let from = model.now.addingTimeInterval(-range.seconds)
        return visibleAccounts.flatMap { account -> [Point] in
            let window = account.weekly?.id ?? "7d"
            var list = model.history.samples(account.id).filter { $0.time >= from }.compactMap { sample -> Point? in
                sample.values[window].map { Point(account: account.id, time: sample.time, value: $0) }
            }
            if list.count > 240 {
                let stride = list.count / 240 + 1
                list = list.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            }
            return list
        }
    }

    private var historyChart: some View {
        let points = points
        return Chart(points) { point in
            LineMark(x: .value("Time", point.time), y: .value("Used", point.value), series: .value("Account", point.account))
                .foregroundStyle(Color(hex: model.identity(point.account).color))
                .lineStyle(StrokeStyle(lineWidth: highlighted == point.account ? 3 : 2, lineCap: .round,
                                       lineJoin: .round))
                .interpolationMethod(.stepEnd)
                .opacity(highlighted == nil || highlighted == point.account ? 1 : 0.2)
        }
        // Room at the right edge, so the label under the last tick is not cut off.
        .chartXScale(domain: model.now.addingTimeInterval(-range.seconds)...model.now,
                     range: .plotDimension(endPadding: 14))
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)").font(.system(size: 8.5)) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                if range == .week {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), collisionResolution: .disabled)
                        .font(.system(size: 8.5))
                } else {
                    AxisValueLabel(format: .dateTime.hour().minute(), collisionResolution: .disabled)
                        .font(.system(size: 8.5))
                }
            }
        }
        .chartLegend(.hidden)
        .chartReadout { (time: Date, _: Double) in readout(points, at: time) }
        .overlay {
            if points.isEmpty { Text("Collecting history…").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    /// Every visible account's weekly reading at the pointer's time: the last one recorded before it.
    private func readout(_ points: [Point], at time: Date) -> ChartReadout<Date>? {
        let x = time.timeIntervalSinceReferenceDate
        var readout = ChartReadout(x: time, title: Format.dayTime(time))
        for account in visibleAccounts {
            let line = points.filter { $0.account == account.id }
                .map { Series.Point(x: $0.time.timeIntervalSinceReferenceDate, y: $0.value) }
            guard let held = Series.held(line, at: x) else { continue }
            let identity = model.identity(account.id)
            let color = Color(hex: identity.color)
            readout.dots.append(.init(y: held.y, color: color))
            readout.rows.append(.init(color: color, text: "\(identity.label) \(Format.percent(held.y))"))
        }
        return readout.rows.isEmpty ? nil : readout
    }

    private var legend: some View {
        FlowRow(horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(visibleAccounts) { account in
                let identity = model.identity(account.id)
                Button { model.selectedAccount = account.id } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: identity.color)).frame(width: 7, height: 7)
                        Text(identity.label).font(.system(size: 10)).fixedSize()
                    }
                }
                .buttonStyle(LinkButtonStyle())
                .onHover { inside in
                    if inside { highlighted = account.id } else if highlighted == account.id { highlighted = nil }
                }
                .help("Point to pick out this line. Click to open the account.")
            }
        }
    }

    private func activityRow(_ account: AccountSnapshot) -> some View {
        let identity = model.identity(account.id)
        let weeklyID = account.weekly?.id ?? "7d"
        let burned = model.history.burned(account: account.id, window: weeklyID, over: range.seconds,
                                          current: account.weekly?.used, now: model.now)
        let burnValue = burned.map { $0 >= 0.5 ? "+\(Int($0.rounded()))%" : "0%" } ?? "—"
        return Button { model.selectedAccount = account.id } label: {
            Card(padding: 9) {
                HStack(alignment: .top, spacing: 10) {
                    Badge(identity: identity, size: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(identity.label).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            if let last = account.lastUsed {
                                Text(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: model.now))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .help("Last request \(Format.dayTime(last))")
                            }
                        }
                        switch account.provider {
                        case .claude:
                            HStack(spacing: 12) {
                                metric(burnValue, "in \(range.rawValue)")
                                metric("\(account.sessions)", "active")
                                metric("\(account.recentRequests)", "recent req.")
                                if let tokens = account.tokens { metric(Format.count(tokens.total), "tokens") }
                            }
                            if !account.recentModels.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(account.recentModels.prefix(3), id: \.self) { id in
                                        Text(Format.modelName(id)).font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                                            .background(Color(hex: identity.color).opacity(0.15), in: Capsule())
                                            .help(id)
                                    }
                                }
                            }
                        case .codex:
                            HStack(spacing: 12) {
                                metric(burnValue, "in \(range.rawValue)")
                                if let resets = account.resets {
                                    metric("\(resets.available)", "banked")
                                }
                                if let plan = account.plan {
                                    metric(plan, "plan")
                                }
                            }
                        case .google:
                            HStack(spacing: 12) {
                                metric(burnValue, "in \(range.rawValue)")
                                if let weekly = account.weekly?.used {
                                    metric(Format.percent(weekly), "weekly")
                                }
                            }
                            Text(account.covers ?? account.error ?? "Google AI")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary).frame(maxHeight: .infinity)
                }
            }
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 11))
        .help(model.windowsSummary(account))
    }

    private func hoverTokens(_ name: String, _ inside: Bool) {
        if inside { hoveredTokens = name } else if hoveredTokens == name { hoveredTokens = nil }
    }

    private func tokenHelp(_ name: String, _ count: Double, of total: Double) -> String {
        let share = count / max(1, total) * 100
        return "\(name): \(Int(count).formatted()) tokens, "
            + (share > 0 && share < 1 ? "under 1%" : Format.percent(share)) + " of the total"
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func tokenCard(_ tokens: TokenTotals) -> some View {
        let parts: [(String, Double, Color)] = [
            ("Cache read", tokens.cacheRead, Color(hex: "#64d2ff")),
            ("Cache write", tokens.cacheCreation, Color(hex: "#5e5ce6")),
            ("Output", tokens.output, Color(hex: "#30d158")),
            ("Input", tokens.input, Color(hex: "#ffd60a")),
        ]
        return Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Tokens through TeamClaude").sectionTitle()
                    Spacer()
                    if let context = model.proxy.activeContext {
                        Text("\(Format.count(context)) active · Anthropic")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Anthropic proxy only").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                GeometryReader { geometry in
                    HStack(spacing: 1.5) {
                        ForEach(parts, id: \.0) { part in
                            Rectangle().fill(part.2.gradient)
                                .frame(width: max(2, geometry.size.width * part.1 / max(1, tokens.total)))
                                .opacity(hoveredTokens == nil || hoveredTokens == part.0 ? 1 : 0.3)
                                .onHover { hoverTokens(part.0, $0) }
                                .help(tokenHelp(part.0, part.1, of: tokens.total))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                HStack(spacing: 0) {
                    ForEach(parts, id: \.0) { part in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Circle().fill(part.2).frame(width: 6, height: 6)
                                Text(part.0).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            }
                            Text(Format.count(part.1)).font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .opacity(hoveredTokens == nil || hoveredTokens == part.0 ? 1 : 0.45)
                        .onHover { hoverTokens(part.0, $0) }
                        .help(tokenHelp(part.0, part.1, of: tokens.total))
                    }
                }
            }
        }
    }
}
