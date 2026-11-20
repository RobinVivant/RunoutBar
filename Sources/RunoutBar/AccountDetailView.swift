import Charts
import SwiftUI
import RunoutCore

struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    var accountID: String

    var body: some View {
        if let account = model.account(accountID) {
            let identity = model.identity(account.id)
            let stale = account.isStale(at: model.now)
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    model.selectedAccount = nil
                } label: {
                    Label("All accounts", systemImage: "chevron.left").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 6))
                .padding(.leading, -6)
                .padding(.top, 4)

                HStack(spacing: 10) {
                    Badge(identity: identity, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(identity.label).font(.system(size: 16, weight: .bold))
                        if account.provider == .claude, !caption(account).isEmpty {
                            Button { model.copy(account.id) } label: {
                                Text(caption(account)).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            }
                            .buttonStyle(LinkButtonStyle())
                            .help("Click to copy the account name")
                        } else {
                            Text(caption(account)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let fetched = account.fetchedAt {
                            Text("checked \(Format.timeSeconds(fetched))").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    routingControl(account)
                }

                if let signIn = account.signIn, model.signInsDue.contains(signIn) { SignInBanner(signIn: signIn) }

                VStack(alignment: .leading, spacing: 5) {
                    if stale {
                        let since = account.fetchedAt.map { " since \(Format.time($0))" } ?? ""
                        Callout(symbol: "exclamationmark.triangle.fill", color: Palette.amber,
                                text: "No fresh reading\(since). \(account.error ?? "")")
                    }
                    if let warning = account.warning {
                        Callout(symbol: "exclamationmark.triangle.fill", color: Palette.amber, text: warning)
                    }
                    if account.blocked {
                        Callout(symbol: "xmark.octagon.fill", color: Palette.red, text: "Included usage blocked by the server")
                    }
                    if let unavailable = account.unavailable {
                        Callout(symbol: "pause.circle.fill", color: .secondary, text: "Out of rotation: \(unavailable)")
                    }
                    switch account.sessionNote {
                    case .noLimit:
                        Callout(symbol: "infinity", color: Palette.ok, text: "No 5-hour limit; weekly limits apply")
                    case .notReportedSince(let date):
                        Callout(symbol: "clock", color: .secondary,
                                text: "No 5-hour window reported since \(Format.dayTime(date)); weekly limits apply")
                    case nil:
                        EmptyView()
                    }
                }

                ForEach(account.windows) { window in
                    WindowCard(account: account, window: window, identity: identity)
                }

                if let resets = account.resets { ResetsCard(account: account, resets: resets) }

                if let covers = account.covers { modelsCard(covers) }

                if account.provider == .claude || !account.recentModels.isEmpty || account.signIn != nil {
                    facts(account)
                }
            }
        }
    }

    private func caption(_ account: AccountSnapshot) -> String {
        var parts: [String] = []
        switch account.provider {
        case .codex: parts.append(account.plan.map { "Codex · \($0)" } ?? "Codex")
        case .google: parts.append("Google AI")
        case .claude: if account.id != model.identity(account.id).label { parts.append(account.id) }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func routingControl(_ account: AccountSnapshot) -> some View {
        if account.provider == .claude, model.proxy.up {
            if account.routing {
                Pill(text: "Routing here", color: Palette.ok, symbol: "checkmark")
            } else {
                Button("Route here") { Task { await model.route(to: account.id) } }
                    .buttonStyle(ActionButtonStyle(prominent: true))
                    .fixedSize()
                    .help("Make the proxy prefer this account for new requests")
            }
        }
    }

    private func facts(_ account: AccountSnapshot) -> some View {
        Card {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if account.provider == .claude {
                    fact("person.2", "Sessions", "\(account.sessions) active · \(account.knownSessions) known")
                    fact("arrow.left.arrow.right", "Requests", "\(account.recentRequests) recent · \(account.totalRequests) total")
                    if let tokens = account.tokens, tokens.total > 0 {
                        fact("text.word.spacing", "Tokens",
                             "\(Format.count(tokens.output)) out · \(Format.count(tokens.cacheRead)) cache read")
                    }
                    if let last = account.lastUsed {
                        fact("clock", "Last used",
                             RelativeDateTimeFormatter().localizedString(for: last, relativeTo: model.now),
                             help: "Last request \(Format.dayTime(last))")
                    }
                    if let extra = account.extraUsage {
                        fact("creditcard", "Extra usage", (extra ? "On" : "Off") + (account.spend.map { " · \($0)" } ?? ""))
                    }
                }
                if let signIn = account.signIn {
                    GridRow {
                        Image(systemName: "key").foregroundStyle(.secondary).frame(width: 14)
                        Text("Sign-in").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(signIn.headline(now: model.now)).lineLimit(1)
                                .foregroundStyle(signIn.stage(at: model.now) == .ok ? AnyShapeStyle(.primary)
                                    : AnyShapeStyle(signIn.stage(at: model.now).color))
                                .help(signIn.explanation(now: model.now))
                            ReconnectControl(signIn: signIn, link: true)
                        }
                    }
                }
                if !account.recentModels.isEmpty {
                    GridRow {
                        Image(systemName: "cpu").foregroundStyle(.secondary).frame(width: 14)
                        Text("Models").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(account.recentModels.prefix(3), id: \.self) { model in
                                Text(Format.modelName(model)).font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                                    .help(model)
                            }
                        }
                    }
                }
            }
            .font(.system(size: 11))
        }
    }

    private func modelsCard(_ covers: String) -> some View {
        let models = covers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Models sharing these limits").sectionTitle()
                if models.count > 1, models.allSatisfy({ $0.count <= 40 }) {
                    FlowRow(horizontalSpacing: 5, verticalSpacing: 5) {
                        ForEach(models, id: \.self) { name in
                            Text(name).font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                                .fixedSize()
                        }
                    }
                } else {
                    Text(covers).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func fact(_ symbol: String, _ title: String, _ value: String, help: String = "") -> some View {
        GridRow {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 14)
            Text(title).foregroundStyle(.secondary)
            Text(value).lineLimit(1).help(help)
        }
    }
}

/// One window: the big number, its reset, and a timeline of the window so far
/// with the projection to the reset.
struct WindowCard: View {
    @Environment(AppModel.self) private var model
    var account: AccountSnapshot
    var window: LimitWindow
    var identity: AccountIdentity

    /// A per-model weekly window with nothing used yet needs no chart.
    private var isUnusedScoped: Bool { window.id.hasPrefix("7d.") && (window.used ?? 0) == 0 }

    var body: some View {
        let stale = account.isStale(at: model.now)
        let pace = model.pace(account, window)
        let color = Color(hex: identity.color)
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(window.title).font(.system(size: 12, weight: .semibold))
                    Text(Format.percent(window.used))
                        .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(stale ? .secondary : Palette.level(window.used, full: model.proxy.threshold))
                    Spacer()
                    if let reset = window.resetsAt {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("resets \(Format.dayTime(reset))").font(.system(size: 10.5))
                            Text("in \(Format.until(reset, now: model.now))").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                        .help("Resets \(Format.day(reset)) at \(Format.time(reset))")
                    } else if window.used == 0 {
                        Text("starts on first use").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    } else {
                        Text("no reset reported").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                if window.used == nil {
                    Text("Not reported").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if isUnusedScoped {
                    EmptyView()
                } else if window.windowStart != nil {
                    WindowTimeline(account: account, window: window, color: stale ? .secondary : color, pace: pace)
                        .frame(height: 82)
                }
                if let pace, let used = window.used, !isUnusedScoped {
                    paceLine(pace, used: used)
                }
            }
        }
    }

    @ViewBuilder
    private func paceLine(_ pace: Pace, used: Double) -> some View {
        let gap = used - pace.even
        let position = abs(gap) < 5 ? "on an even pace"
            : gap > 0 ? "\(Int(gap.rounded()))% ahead of even pace" : "\(Int((-gap).rounded()))% under even pace"
        let rate = pace.ratePerHour.map { String(format: "%.1f%%/h", $0) }
        let basis = [rate, pace.basis?.rawValue].compactMap { $0 }.joined(separator: ", ")
        VStack(alignment: .leading, spacing: 3) {
            Callout(symbol: "gauge.with.needle", color: .secondary, text: "Even pace now \(Int(pace.even.rounded()))% · \(position)")
            if let fullAt = pace.fullAt {
                Callout(symbol: "bolt.fill", color: Palette.amber,
                        text: "Full \(Format.dayTime(fullAt)), in \(Format.until(fullAt, now: model.now)), before the reset"
                            + (basis.isEmpty ? "" : " (\(basis))"))
            } else if used < model.proxy.threshold {
                Callout(symbol: "chart.line.uptrend.xyaxis", color: .secondary,
                        text: "About \(Int(pace.atReset.rounded()))% at reset" + (basis.isEmpty ? "" : " (\(basis))"))
            }
        }
    }
}

struct WindowTimeline: View {
    @Environment(AppModel.self) private var model
    var account: AccountSnapshot
    var window: LimitWindow
    var color: Color
    var pace: Pace?

    struct Point: Identifiable {
        var id: Date { time }
        var time: Date
        var value: Double
    }

    var body: some View {
        let start = window.windowStart ?? model.now
        let end = window.resetsAt ?? model.now
        let points = trail(start: start)
        let threshold = model.proxy.threshold
        Chart {
            LineMark(x: .value("Time", start), y: .value("Used", 0), series: .value("S", "even"))
                .foregroundStyle(Color.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            LineMark(x: .value("Time", end), y: .value("Used", 100), series: .value("S", "even"))
                .foregroundStyle(Color.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            RuleMark(y: .value("Limit", threshold))
                .foregroundStyle(Palette.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            // A window starts at 0%; until history covers it, join the start with a faint dotted line.
            if let first = points.first, first.time > start.addingTimeInterval(window.duration.map { $0 * 0.02 } ?? 0) {
                ForEach([Point(time: start, value: 0), first]) { point in
                    LineMark(x: .value("Time", point.time), y: .value("Used", point.value), series: .value("S", "lead-in"))
                        .foregroundStyle(color.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [1, 3]))
                }
            }
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.time), y: .value("Used", point.value))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.03)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.time), y: .value("Used", point.value), series: .value("S", "used"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = points.last, let pace {
                let target = pace.fullAt.map { Point(time: $0, value: threshold) }
                    ?? Point(time: end, value: pace.atReset)
                ForEach([last, target]) { point in
                    LineMark(x: .value("Time", point.time), y: .value("Used", point.value), series: .value("S", "projection"))
                        .foregroundStyle(pace.fullAt != nil ? Palette.amber : color.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            RuleMark(x: .value("Now", model.now))
                .foregroundStyle(Color.primary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartXScale(domain: start...max(end, start.addingTimeInterval(60)))
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)").font(.system(size: 8.5)) }
            }
        }
        .chartXAxis {
            if (window.duration ?? 0) > 86_400 {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true).font(.system(size: 8.5))
                }
            } else {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel(format: .dateTime.hour()).font(.system(size: 8.5))
                }
            }
        }
        .chartReadout { (time: Date, _: Double) in
            readout(points, at: time, start: start, end: end, threshold: threshold)
        }
    }

    /// The reading nearest the pointer, or past now the projection there.
    private func readout(_ points: [Point], at time: Date, start: Date, end: Date,
                         threshold: Double) -> ChartReadout<Date>? {
        guard let last = points.last, end > start else { return nil }
        let even = "even pace " + Format.percent(time.timeIntervalSince(start) / end.timeIntervalSince(start) * 100)
        if time > last.time {
            guard let pace else { return nil }
            let target = pace.fullAt.map { Point(time: $0, value: threshold) } ?? Point(time: end, value: pace.atReset)
            let line = [last, target].map { Series.Point(x: $0.time.timeIntervalSinceReferenceDate, y: $0.value) }
            guard let value = Series.interpolate(line, at: time.timeIntervalSinceReferenceDate) else { return nil }
            let tint = pace.fullAt != nil ? Palette.amber : color
            return ChartReadout(x: time, dots: [.init(y: value, color: tint)], title: Format.dayTime(time),
                                rows: [.init(color: tint, text: "about \(Format.percent(value)) projected"),
                                       .init(text: even)])
        }
        let line = points.map { Series.Point(x: $0.time.timeIntervalSinceReferenceDate, y: $0.value) }
        guard let near = Series.nearest(line, to: time.timeIntervalSinceReferenceDate) else { return nil }
        let at = Date(timeIntervalSinceReferenceDate: near.x)
        return ChartReadout(x: at, dots: [.init(y: near.y, color: color)], title: Format.dayTime(at),
                            rows: [.init(color: color, text: "\(Format.percent(near.y)) used"), .init(text: even)])
    }

    private func trail(start: Date) -> [Point] {
        var points = model.history.samples(account.id).compactMap { sample -> Point? in
            guard sample.time >= start, sample.time <= model.now, let value = sample.values[window.id] else { return nil }
            return Point(time: sample.time, value: value)
        }
        if points.count > 200 {
            let stride = points.count / 200 + 1
            points = points.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
        }
        if let used = window.used, !account.isStale(at: model.now) {
            points.removeAll { $0.time >= model.now }
            points.append(Point(time: model.now, value: used))
        }
        return points
    }
}
