import AppKit
import SwiftUI
import RunoutCore

/// `RunoutBar --snapshot <dir>`: refresh once (live data, or made-up data with `--demo`), then render the
/// menu bar glyph and every popover screen to PNG. Used to check layouts and
/// to produce README images without clicking through the menu bar.
@MainActor
enum SnapshotRunner {
    static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel()
        model.startForSnapshot()
        await model.refresh(force: true)
        await model.checkForUpdates(force: true)

        // One Claude account's reset listing: a live read (which spends nothing), or a made-up
        // listing when Anthropic rate-limits the read, so the layout can still be checked.
        let claudeSample = model.accounts.first { $0.provider == .claude && $0.resets != nil }?.id
        if let claudeSample {
            await model.loadClaudeResets(claudeSample)?.value
            if model.claudeResets[claudeSample] == nil, let sample = sampleResets() {
                print("Claude resets: sample listing (\(model.claudeResetsError[claudeSample]?.message ?? "no reading"))")
                model.showClaudeResetsForSnapshot(claudeSample, sample)
            } else {
                print("Claude resets: \(model.demo ? "demo" : "live") listing")
            }
        }

        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            for tab in Tab.allCases {
                model.tab = tab
                model.selectedAccount = nil
                await render(model, scheme: scheme, to: directory.appendingPathComponent("\(tab.rawValue.lowercased())-\(suffix).png"))
            }
            model.tab = .usage
            for account in model.accounts {
                model.selectedAccount = account.id
                let name = model.identity(account.id).label.lowercased().replacingOccurrences(of: " ", with: "-")
                await render(model, scheme: scheme, to: directory.appendingPathComponent("detail-\(name)-\(suffix).png"))
                if account.provider == .codex, account.resets != nil {
                    model.resetArmed = ResetTarget(account: account.id)  // the confirmation step; nothing is spent
                    await render(model, scheme: scheme, to: directory.appendingPathComponent("detail-\(name)-confirm-\(suffix).png"))
                    model.resetArmed = nil
                }
                if account.id == claudeSample, let grant = model.claudeResets[account.id]?.grants.first {
                    await render(model, scheme: scheme, to: directory.appendingPathComponent("detail-\(name)-resets-\(suffix).png"))
                    model.resetArmed = ResetTarget(account: account.id, grant: grant.id)
                    await render(model, scheme: scheme, to: directory.appendingPathComponent("detail-\(name)-confirm-\(suffix).png"))
                    model.resetArmed = nil
                    // A made-up queue: this account's spend and another account's read both wait
                    // for a rate limit to clear. Nothing is sent.
                    let other = model.accounts.first { $0.provider == .claude && $0.resets != nil && $0.id != account.id }
                    model.showQueueForSnapshot(sampleQueue(spend: account.id, read: other?.id, labels: model.identity),
                                               loading: Set([other?.id].compactMap { $0 }), applying: account.id)
                    await render(model, scheme: scheme, to: directory.appendingPathComponent("detail-\(name)-held-\(suffix).png"))
                    if let other {
                        model.selectedAccount = other.id
                        await render(model, scheme: scheme, to: directory.appendingPathComponent("detail-read-held-\(suffix).png"))
                    }
                    model.showQueueForSnapshot(APIQueue.Snapshot())
                }
            }
        }
        model.selectedAccount = nil

        let glyph = StatusGlyph.image(bars: model.glyphBars, warning: !model.proxy.up)
        writePNG(titled(glyph, model.statusTitle), scale: 4, to: directory.appendingPathComponent("glyph.png"))
        print("Rendered snapshots to \(directory.path)")
        print("Accounts: \(model.accounts.map { "\($0.id.prefix(3))… \(Format.percent($0.peak))" })")
        print("Run-out: " + (model.runOut.map { "\($0.state.rawValue): " + model.runOutSentence($0) } ?? "none"))
        print("Proxy up: \(model.proxy.up), version \(model.proxy.version ?? "-"), latest \(model.latestTeamClaude ?? "-")")
    }

    private static func sampleQueue(spend: String, read: String?, labels: (String) -> AccountIdentity) -> APIQueue.Snapshot {
        let until = Date().addingTimeInterval(160)
        var queue = APIQueue.Snapshot()
        queue.entries = [APIQueue.Entry(lane: AppModel.lane(spend, .spend), label: "Spend a reset: \(labels(spend).label)",
                                        state: .held(until: until), attempts: 1)]
        queue.holds = [AppModel.lane(spend, .spend): until]
        if let read {
            let later = until.addingTimeInterval(95)
            queue.entries.append(APIQueue.Entry(lane: AppModel.lane(read, .read), label: "Read resets: \(labels(read).label)",
                                                state: .held(until: later), attempts: 2))
            queue.holds[AppModel.lane(read, .read)] = later
        }
        return queue
    }

    private static func sampleResets() -> ClaudeResetStatus? {
        let week = Date().addingTimeInterval(9 * 86_400).timeIntervalSince1970 * 1000
        let json = """
        {"ok": true, "eligible": true, "atLimit": false, "exhausted": [], "nextGrantId": "sample-weekly", "grants": [
          {"id": "sample-weekly", "kind": "weekly", "resetsLeft": 2, "resetsTotal": 3,
           "clears": ["five_hour", "seven_day"], "endsAt": \(week), "usableNow": true, "paused": false},
          {"id": "sample-fable", "kind": "fable", "resetsLeft": 1, "resetsTotal": 1,
           "clears": ["seven_day_overage_included"], "endsAt": \(week * 1.0002), "usableNow": false, "paused": false,
           "unavailableReason": "not_limited"}]}
        """
        return try? ClaudeResets.parseStatus(JSONValue.parse(Data(json.utf8)), now: Date())
    }

    /// Draws the popover in a window that never comes on screen. A window, unlike `ImageRenderer`,
    /// also draws the AppKit-backed controls (segmented pickers, menus).
    private static func render(_ model: AppModel, scheme: ColorScheme, to url: URL) async {
        let view = PopoverView(scrolls: false)
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        // Charts and pickers finish laying out a moment after they join a window.
        try? await Task.sleep(for: .milliseconds(120))
        window.setContentSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds, scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        window.close()
        try? rounded(rep, radius: 14 * scale)?.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The image with the popover's rounded corners, transparent outside them.
    private static func rounded(_ source: NSBitmapImageRep, radius: CGFloat) -> NSBitmapImageRep? {
        guard let image = source.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return source }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(image, in: rect)
        return context.makeImage().map { NSBitmapImageRep(cgImage: $0) }
    }

    /// The glyph followed by the status item's title, as the menu bar lays them out.
    private static func titled(_ glyph: NSImage, _ title: NSAttributedString) -> NSImage {
        guard title.length > 0 else { return glyph }
        let textSize = title.size()
        let size = NSSize(width: glyph.size.width + textSize.width, height: max(glyph.size.height, textSize.height))
        return NSImage(size: size, flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: (size.height - glyph.size.height) / 2, width: glyph.size.width,
                                  height: glyph.size.height))
            title.draw(at: NSPoint(x: glyph.size.width, y: (size.height - textSize.height) / 2))
            return true
        }
    }

    /// The glyph on a menu-bar-grey strip, enlarged.
    private static func writePNG(_ image: NSImage, scale: CGFloat, to url: URL) {
        let pad: CGFloat = 6
        let size = NSSize(width: (image.size.width + pad * 2) * scale, height: (image.size.height + pad) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            NSColor(white: 0.17, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            image.draw(in: NSRect(x: pad * scale, y: pad / 2 * scale, width: image.size.width * scale,
                                  height: image.size.height * scale))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
