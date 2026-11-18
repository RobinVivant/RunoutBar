import AppKit
import RunoutCore

struct GlyphBar {
    /// 0 to 1, or nil when there is no fresh reading.
    var fraction: Double?
    var color: NSColor
    var routed: Bool
}

/// The menu bar image: one rounded level bar per account, a dot under the
/// account the proxy routes to. Drawn lazily, so the track colour follows the
/// menu bar's light or dark appearance.
enum StatusGlyph {
    static let barWidth: CGFloat = 4.5
    static let gap: CGFloat = 2.5
    static let barHeight: CGFloat = 13
    static let baseY: CGFloat = 4

    static func image(bars: [GlyphBar], warning: Bool) -> NSImage {
        let warningWidth: CGFloat = warning ? 16 : 0
        let barsWidth = CGFloat(bars.count) * barWidth + CGFloat(max(0, bars.count - 1)) * gap
        let size = NSSize(width: max(warningWidth + barsWidth, 8), height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            if warning {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
                NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Proxy down")?
                    .withSymbolConfiguration(config)?
                    .draw(in: NSRect(x: 0, y: 3, width: 13, height: 12))
                x = warningWidth
            }
            let radius = barWidth / 2
            for bar in bars {
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
                    NSBezierPath(ovalIn: NSRect(x: x + barWidth / 2 - 1.3, y: 0.2, width: 2.6, height: 2.6)).fill()
                }
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension AppModel {
    var glyphBars: [GlyphBar] {
        accounts.map { account in
            let identity = identity(account.id)
            let fresh = !account.isStale(at: now)
            var color = NSColor(hex: identity.color)
            switch account.tier(at: now, full: proxy.threshold) {
            case .full: color = .systemRed
            case .high: color = .systemOrange
            default: break
            }
            return GlyphBar(fraction: fresh ? account.peak.map { $0 / 100 } : nil,
                            color: fresh ? color : .tertiaryLabelColor, routed: account.routing)
        }
    }

    private func shown(_ used: Double) -> Int {
        Int((numberMode == .left ? 100 - used : used).rounded())
    }

    /// Text beside the glyph, or the whole title in letters mode, then the pool run-out time.
    var statusTitle: NSAttributedString {
        let title = NSMutableAttributedString(attributedString: accountsTitle)
        if showRunOut, let runOut {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            title.append(NSAttributedString(string: " " + runOutLabel(runOut),
                                            attributes: [.font: font, .foregroundColor: runOut.state.nsColor]))
        }
        return title
    }

    /// "Thu 15:40", "out", or a check mark when the pool lasts well past the target.
    func runOutLabel(_ runOut: PoolRunOut) -> String {
        if let at = runOut.at, at <= now { return "out" }
        return runOut.shownDate(now: now).map(Format.dayTime) ?? "✓"
    }

    /// One line on the pool run-out, for the tooltip.
    func runOutSentence(_ runOut: PoolRunOut) -> String {
        let target = Format.dayTime(runOut.target)
        let pace = String(format: "%.1f pts per work hour", runOut.ratePerWorkHour)
        guard let at = runOut.at else { return "Claude pool lasts past \(target) and the week after (\(pace))" }
        if at <= now { return "Claude pool is out" }
        let margin = Format.duration(abs(runOut.margin ?? 0))
        return at < runOut.target
            ? "Claude pool runs out \(Format.dayTime(at)), \(margin) before \(target) (\(pace))"
            : "Claude pool lasts past \(target): runs out \(Format.dayTime(at)) (\(pace))"
    }

    private var accountsTitle: NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        switch menuBarStyle {
        case .bars:
            return NSAttributedString()
        case .barsAndPercent:
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
        let parts = accounts.map { account -> String in
            let identity = identity(account.id)
            guard !account.isStale(at: now), let peak = account.peak else { return "\(identity.label) ?" }
            return "\(identity.label) \(shown(peak))%" + (account.routing ? " (routing)" : "")
        }
        let runOutLine = runOut.map { "\n" + runOutSentence($0) } ?? ""
        return "\(what): " + parts.joined(separator: " · ") + runOutLine
            + (proxy.up ? "" : "\nTeamClaude proxy not responding")
    }
}

extension PoolRunOut.State {
    var nsColor: NSColor {
        switch self {
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
