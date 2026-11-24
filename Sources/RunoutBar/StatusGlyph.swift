import AppKit
import RunoutCore

struct GlyphBar {
    /// 0 to 1, or nil when there is no fresh reading.
    var fraction: Double?
    var color: NSColor
    var routed: Bool
}

struct GlyphGroup {
    var bars: [GlyphBar]
    var pooled: Bool
}

/// The menu bar image: grouped rounded level bars separated by source, a pool rail under
/// multi-account TeamClaude bars, and a dot under the active routed account. Drawn lazily,
/// so track and divider colors follow light or dark menu bar appearance.
enum StatusGlyph {
    static let barWidth: CGFloat = 4.5
    static let gap: CGFloat = 2.5
    static let groupGap: CGFloat = 7.0
    static let barHeight: CGFloat = 12.5
    static let baseY: CGFloat = 4.5

    static func image(groups: [GlyphGroup], warning: Bool) -> NSImage {
        let nonEmpty = groups.filter { !$0.bars.isEmpty }
        let warningWidth: CGFloat = warning ? 16 : 0
        var barsWidth: CGFloat = 0
        for (groupIndex, group) in nonEmpty.enumerated() {
            if groupIndex > 0 { barsWidth += groupGap }
            barsWidth += CGFloat(group.bars.count) * barWidth + CGFloat(max(0, group.bars.count - 1)) * gap
        }
        let size = NSSize(width: max(warningWidth + barsWidth, 8), height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            if warning {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
                NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Source warning")?
                    .withSymbolConfiguration(config)?
                    .draw(in: NSRect(x: 0, y: 3, width: 13, height: 12))
                x = warningWidth
            }
            let radius = barWidth / 2
            for (groupIndex, group) in nonEmpty.enumerated() {
                if groupIndex > 0 {
                    let dividerX = x + (groupGap - 1) / 2
                    NSColor.labelColor.withAlphaComponent(0.22).setFill()
                    NSRect(x: dividerX, y: baseY + 1, width: 1, height: barHeight - 2).fill()
                    x += groupGap
                }
                let groupStartX = x
                for (barIndex, bar) in group.bars.enumerated() {
                    if barIndex > 0 { x += gap }
                    let track = NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barWidth, height: barHeight),
                                             xRadius: radius, yRadius: radius)
                    NSColor.labelColor.withAlphaComponent(0.2).setFill()
                    track.fill()
                    if let fraction = bar.fraction, fraction > 0 {
                        // Clip to the track so low values stay true to scale instead of a full round cap.
                        let height = max(1, barHeight * CGFloat(min(1, fraction)))
                        NSGraphicsContext.saveGraphicsState()
                        track.addClip()
                        bar.color.setFill()
                        NSRect(x: x, y: baseY, width: barWidth, height: height).fill()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    if bar.routed {
                        NSColor.labelColor.setFill()
                        NSBezierPath(ovalIn: NSRect(x: x + barWidth / 2 - 1.4, y: 0.4, width: 2.8, height: 2.8)).fill()
                    }
                    x += barWidth
                }
                if group.pooled && group.bars.count > 1 {
                    let railRect = NSRect(x: groupStartX, y: 1.4, width: x - groupStartX, height: 1.0)
                    NSColor.labelColor.withAlphaComponent(0.3).setFill()
                    NSBezierPath(roundedRect: railRect, xRadius: 0.5, yRadius: 0.5).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension AppModel {
    var glyphGroups: [GlyphGroup] {
        switch menuBarGrouping {
        case .accounts:
            return providerSections.map { section in
                let bars = section.accounts.map { account in
                    let identity = identity(account.id)
                    let fresh = !account.isStale(at: now)
                    var color = NSColor(hex: identity.color)
                    switch account.tier(at: now, full: account.effectiveThreshold(proxyThreshold: proxy.threshold)) {
                    case .full: color = .systemRed
                    case .high: color = .systemOrange
                    default: break
                    }
                    return GlyphBar(fraction: fresh ? account.peak.map { $0 / 100 } : nil,
                                    color: fresh ? color : .tertiaryLabelColor, routed: account.routing)
                }
                return GlyphGroup(bars: bars, pooled: section.provider == .claude)
            }
        case .lanes:
            let runOutByID = Dictionary(uniqueKeysWithValues: globalRunOut.lanes.map { ($0.id, $0) })
            return providerSections.map { section in
                if section.provider == .claude {
                    let lane = lanes.first { $0.provider == .claude }
                    let routedAccount = section.accounts.first(where: \.routing) ?? section.accounts.first
                    let routedIdentity = routedAccount.map { identity($0.id) }
                    let allExhausted = summary.exhausted
                    let weeklyUsed = lane?.weeklyUsed(at: now)
                    let fraction = allExhausted ? 1.0 : weeklyUsed.map { $0 / 100 }
                    let runOutState = runOutByID["claude"]?.runOut?.state
                    let color: NSColor
                    if weeklyUsed == nil {
                        color = .tertiaryLabelColor
                    } else if allExhausted || runOutState == .critical {
                        color = .systemRed
                    } else if runOutState == .short {
                        color = .systemOrange
                    } else {
                        color = NSColor(hex: routedIdentity?.color ?? AppConfig.palette[0])
                    }
                    return GlyphGroup(
                        bars: [GlyphBar(fraction: fraction, color: color, routed: proxy.up)],
                        pooled: true
                    )
                }
                let bars = section.accounts.map { account in
                    let identity = identity(account.id)
                    let fresh = !account.isStale(at: now)
                    var color = NSColor(hex: identity.color)
                    switch account.tier(at: now, full: account.effectiveThreshold(proxyThreshold: proxy.threshold)) {
                    case .full: color = .systemRed
                    case .high: color = .systemOrange
                    default: break
                    }
                    return GlyphBar(fraction: fresh ? account.peak.map { $0 / 100 } : nil,
                                    color: fresh ? color : .tertiaryLabelColor, routed: false)
                }
                return GlyphGroup(bars: bars, pooled: false)
            }
        }
    }

    private func shown(_ used: Double) -> Int {
        Int((numberMode == .left ? 100 - used : used).rounded())
    }

    /// Text beside the glyph, or the whole title in letters mode, then the work-week run-out time.
    var statusTitle: NSAttributedString {
        let title = NSMutableAttributedString(attributedString: accountsTitle)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        switch menuBarRunOutMode {
        case .off:
            break
        case .claudeOnly:
            if let runOut {
                title.append(NSAttributedString(string: " " + runOutLabel(runOut),
                                                attributes: [.font: font, .foregroundColor: runOut.state.nsColor]))
            }
        case .earliest:
            if let bottleneck = globalRunOut.bottleneck, let runOut = bottleneck.runOut {
                let text = " \(shortTag(for: bottleneck.lane)) \(runOutLabel(runOut))"
                title.append(NSAttributedString(string: text,
                                                attributes: [.font: font, .foregroundColor: runOut.state.nsColor]))
            } else if globalRunOut.state == .lasts {
                title.append(NSAttributedString(string: " ✓",
                                                attributes: [.font: font, .foregroundColor: NSColor.systemGreen]))
            }
        }
        return title
    }

    /// "Thu 15:40", "out", or a check mark when the lane lasts well past the target.
    func runOutLabel(_ runOut: PoolRunOut) -> String {
        if let at = runOut.at, at <= now { return "out" }
        return runOut.shownDate(now: now).map(Format.dayTime) ?? "✓"
    }

    /// One line on a lane's work-week run-out, for tooltips.
    func runOutSentence(_ runOut: PoolRunOut, laneTitle: String = "Claude pool") -> String {
        let target = Format.dayTime(runOut.target)
        let unit = laneTitle == "Claude pool" ? "pts" : "%"
        let pace = String(format: "%.1f %@ per work hour", runOut.ratePerWorkHour, unit)
        if runOut.state == .idle { return "\(laneTitle) is idle" }
        guard let at = runOut.at else { return "\(laneTitle) lasts past \(target) and the week after (\(pace))" }
        if at <= now { return "\(laneTitle) is out" }
        let margin = Format.duration(abs(runOut.margin ?? 0))
        return at < runOut.target
            ? "\(laneTitle) runs out \(Format.dayTime(at)), \(margin) before \(target) (\(pace))"
            : "\(laneTitle) lasts past \(target): runs out \(Format.dayTime(at)) (\(pace))"
    }

    private var accountsTitle: NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        switch menuBarStyle {
        case .bars:
            return NSAttributedString()
        case .barsAndPercent:
            if menuBarGrouping == .lanes, let claude = lanes.first(where: { $0.provider == .claude }),
               let used = claude.weeklyUsed(at: now) {
                return NSAttributedString(string: " \(shown(used))%", attributes: plain)
            }
            let routed = accounts.first(where: \.routing) ?? accounts.first
            guard let routed, let peak = routed.peak, !routed.isStale(at: now) else {
                return NSAttributedString(string: " ?", attributes: plain)
            }
            return NSAttributedString(string: " \(shown(peak))%", attributes: plain)
        case .letters:
            let title = NSMutableAttributedString()
            for (index, account) in accounts.enumerated() {
                let identity = identity(account.id)
                let letterFont = NSFont.systemFont(ofSize: 12, weight: .bold)
                title.append(NSAttributedString(string: (index == 0 ? "" : " ") + identity.letter,
                                                attributes: [.font: letterFont,
                                                             .foregroundColor: NSColor(hex: identity.color)]))
                let value = account.isStale(at: now) ? "?" : account.peak.map { String(shown($0)) } ?? "?"
                let partial = account.isPartial(at: now) ? "*" : ""
                title.append(NSAttributedString(string: value + partial, attributes: plain))
            }
            return title
        }
    }

    var statusTooltip: String {
        let what = numberMode == .left ? "Remaining" : "Highest used"
        var lines: [String] = []
        for section in providerSections {
            let header: String
            switch section.provider {
            case .claude: header = "Claude (TeamClaude)"
            case .codex: header = "Codex (Direct)"
            case .google: header = "Google AI (Direct)"
            }
            let parts = section.accounts.map { account -> String in
                let identity = identity(account.id)
                guard !account.isStale(at: now), let peak = account.peak else { return "\(identity.label) ?" }
                return "\(identity.label) \(shown(peak))%" + (account.routing ? " (routing)" : "")
            }
            lines.append("\(header): " + parts.joined(separator: " · "))
        }
        if lines.isEmpty {
            lines.append("\(what): no accounts")
        } else {
            lines[0] = "\(what) — " + lines[0]
        }
        for entry in globalRunOut.lanes {
            guard let r = entry.runOut, r.state != .idle else { continue }
            let title = entry.lane.provider == .claude ? "Claude pool" : entry.lane.title
            lines.append(runOutSentence(r, laneTitle: title))
        }
        for signIn in signIns where signIn.stage(at: now) > .ok {
            lines.append("\(signInLabel(signIn)): \(signIn.headline(now: now).lowercased())")
        }
        if !teamClaudeDisabled, !proxy.up {
            lines.append(teamClaudeFound ? "TeamClaude proxy not responding" : "TeamClaude is not installed")
        }
        return lines.joined(separator: "\n")
    }
}

extension PoolRunOut.State {
    var nsColor: NSColor {
        switch self {
        case .idle: return .secondaryLabelColor
        case .lasts: return .systemGreen
        case .short: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0x8e8e93
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
