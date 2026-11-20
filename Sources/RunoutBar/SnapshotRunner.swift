import AppKit
import SwiftUI
import RunoutCore

/// `RunoutBar --snapshot <dir>`: refresh once (live data, or made-up data with `--demo`), then render the
/// menu bar glyph and every popover screen to PNG. Used to check layouts and
/// to produce README images without clicking through the menu bar.
/// `--pointer <x>,<y>` draws every screen as it looks with the pointer there, in points from the
/// top left: the way to check a hover state.
@MainActor
enum SnapshotRunner {
    /// Where `--pointer` puts the pointer, if given.
    private static let pointer: CGPoint? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--pointer"), index + 1 < arguments.count else { return nil }
        let parts = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }()

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
            // A sign-in being renewed, and a renewal that reached another account. No login is run.
            if let due = model.signInsDue.first {
                model.tab = .usage
                model.showReconnectForSnapshot(due.id, .waiting)
                await render(model, scheme: scheme, to: directory.appendingPathComponent("signin-waiting-\(suffix).png"))
                model.showReconnectForSnapshot(due.id, .failed("The browser was signed in to another account, so the "
                    + "sign-in went to that one. Sign in to \(model.signInSite(due)) as \(due.account) and reconnect again."))
                await render(model, scheme: scheme, to: directory.appendingPathComponent("signin-other-\(suffix).png"))
                model.showReconnectForSnapshot(due.id, .done("Signed in again. Good until "
                    + "\(Format.day(Date().addingTimeInterval(30 * 86_400)))."))
                await render(model, scheme: scheme, to: directory.appendingPathComponent("signin-done-\(suffix).png"))
                model.showReconnectForSnapshot(nil, .idle)
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
            // A Mac without TeamClaude, the install under way, and a proxy with no account yet. Nothing is installed.
            if model.demo {
                model.selectedAccount = nil
                // An account whose weekly limit was just cleared by a banked reset, with its session full.
                model.showResetSpentForSnapshot()
                await render(model, scheme: scheme, to: directory.appendingPathComponent("usage-reset-\(suffix).png"))
                await model.refresh(force: true)
                model.showSetupForSnapshot(.missing(traces: false), .idle, blocker: "It needs Node.js "
                    + "\(TeamClaudeInstall.minimumNode) or later, and none was found. Install Node, for example with: "
                    + "brew install node", noAccounts: true)
                await render(model, scheme: scheme, to: directory.appendingPathComponent("setup-node-\(suffix).png"))
                model.showSetupForSnapshot(.missing(traces: false), .installing("Installing TeamClaude 1.1.31 with npm"),
                                           noAccounts: true)
                model.tab = .proxy
                await render(model, scheme: scheme, to: directory.appendingPathComponent("setup-installing-\(suffix).png"))
                model.tab = .usage
                model.showSetupForSnapshot(.missing(traces: false), .idle, noAccounts: true, elsewhere: true)
                await render(model, scheme: scheme, to: directory.appendingPathComponent("setup-elsewhere-\(suffix).png"))
                model.showSetupForSnapshot(.found(""), .failed(TeamClaudeInstall.InstallError.notStarted.localizedDescription))
                await render(model, scheme: scheme, to: directory.appendingPathComponent("setup-failed-\(suffix).png"))
                await model.refresh(force: true)
                model.showSetupForSnapshot(.found(""), .idle, noAccounts: true)
                await render(model, scheme: scheme, to: directory.appendingPathComponent("setup-account-\(suffix).png"))
                await model.refresh(force: true)
                model.showGoogleSignedOutForSnapshot()
                await render(model, scheme: scheme, to: directory.appendingPathComponent("signin-google-\(suffix).png"))
                await model.refresh(force: true)
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
        if let pointer {
            await hover(hosting, in: window, at: NSPoint(x: pointer.x, y: hosting.bounds.height - pointer.y))
        }
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

    /// Tells the view the pointer is at `location`. A window that is not on screen gets no tracking
    /// events of its own, so the entered and moved events are handed to the view directly.
    private static func hover(_ hosting: NSView, in window: NSWindow, at location: NSPoint) async {
        let now = ProcessInfo.processInfo.systemUptime
        for area in hosting.trackingAreas {
            // AppKit finds an entered event's tracking area through this number, which is its address.
            let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: location, modifierFlags: [],
                                                 timestamp: now, windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, trackingNumber: unsafeBitCast(area, to: Int.self),
                                                 userData: nil)
            if let entered { hosting.mouseEntered(with: entered) }
        }
        let moved = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: now,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
                                       pressure: 0)
        if let moved { hosting.mouseMoved(with: moved) }
        // Hover states animate in.
        try? await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
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
