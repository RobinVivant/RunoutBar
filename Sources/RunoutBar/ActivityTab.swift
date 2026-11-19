import Charts
import SwiftUI
import RunoutCore

struct ActivityTab: View {
    @Environment(AppModel.self) private var model
    @State private var range: Range = .day
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

    struct Point: Identifiable {
        var id: String { "\(account)-\(time.timeIntervalSince1970)" }
        var account: String
        var time: Date
        var value: Double
    }

    var body: some View {
        VStack(spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Weekly usage").sectionTitle()
                        Spacer()
                        Picker("Range", selection: $range) {
                            ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 150).controlSize(.mini)
                    }
                    historyChart.frame(height: 130).padding(.trailing, 10)
                    legend
                }
            }
            VStack(spacing: 6) {
                ForEach(model.accounts) { account in
                    activityRow(account)
                }
            }
            if let tokens = model.proxy.tokens, tokens.total > 0 {
                tokenCard(tokens)
            }
        }
    }

    private var points: [Point] {
        let from = model.now.addingTimeInterval(-range.seconds)
        return model.accounts.flatMap { account -> [Point] in
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

    /// Every account's weekly reading at the pointer's time: the last one recorded before it.
    private func readout(_ points: [Point], at time: Date) -> ChartReadout<Date>? {
        let x = time.timeIntervalSinceReferenceDate
        var readout = ChartReadout(x: time, title: Format.dayTime(time))
        for account in model.accounts {
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
        HStack(spacing: 10) {
            ForEach(model.accounts) { account in
                let identity = model.identity(account.id)
                Button { model.selectedAccount = account.id } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: identity.color)).frame(width: 7, height: 7)
                        Text(identity.label).font(.system(size: 10))
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
                        if account.provider == .claude {
                            HStack(spacing: 12) {
                                metric("\(account.sessions)", "active")
                                metric("\(account.knownSessions)", "sessions")
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
                        } else {
                            Text([account.plan, account.resets.map { "\($0.available) reset\($0.available == 1 ? "" : "s") banked" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
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
                    Text("Tokens through the proxy").sectionTitle()
                    Spacer()
                    if let context = model.proxy.activeContext {
                        Text("\(Format.count(context)) in active context").font(.system(size: 10)).foregroundStyle(.secondary)
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
