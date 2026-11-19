import SwiftUI
import RunoutCore

/// How soon a banked reset expiring counts as worth a warning colour.
private let expirySoon: TimeInterval = 3 * 86_400

/// Banked resets across the accounts, on one line. Each chip opens its account.
struct ResetsStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let holders = model.accounts.filter { ($0.resets?.available ?? 0) > 0 }
        let total = model.bankedResets
        let expiry = holders.compactMap { $0.resets?.nextExpiry }.filter { $0 > model.now }.min()
        Card(padding: 9) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(total) reset\(total == 1 ? "" : "s") banked").font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let expiry {
                        let soon = expiry.timeIntervalSince(model.now) < expirySoon
                        Text("first expires \(Format.day(expiry))")
                            .font(.system(size: 10)).foregroundStyle(soon ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .help("in \(Format.until(expiry, now: model.now))")
                    } else {
                        Text("no expiry reported").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(holders) { account in
                        chip(account)
                    }
                }
                .fixedSize()
            }
            .help("A banked reset clears an account's limits before their own reset. Open an account for what it "
                + "holds and how to spend one.")
        }
    }

    private func chip(_ account: AccountSnapshot) -> some View {
        let identity = model.identity(account.id)
        let count = account.resets?.available ?? 0
        return Button {
            model.selectedAccount = account.id
        } label: {
            HStack(spacing: 3) {
                Badge(identity: identity, size: 16)
                Text("\(count)").font(.system(size: 11.5, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .padding(.leading, 3).padding(.trailing, 6).padding(.vertical, 3)
            .background(Color(hex: identity.color).opacity(0.14), in: Capsule())
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 11))
        .help("\(identity.label): \(count) banked. Click to open the account.")
    }
}

/// One account's banked resets, with the control that spends one where this app can.
struct ResetsCard: View {
    @Environment(AppModel.self) private var model
    var account: AccountSnapshot
    var resets: ResetCredits

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Banked resets").font(.system(size: 12, weight: .semibold))
                    Text("\(resets.available)").font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    if let expiry = resets.nextExpiry {
                        let soon = expiry.timeIntervalSince(model.now) < expirySoon
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("first expires \(Format.day(expiry))").font(.system(size: 10.5))
                                .foregroundStyle(soon ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(.primary))
                            Text("in \(Format.until(expiry, now: model.now))").font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                    }
                }
                if account.provider == .codex {
                    codexBody
                } else {
                    claudeBody
                }
            }
        }
    }

    // MARK: Claude

    @ViewBuilder
    private var claudeBody: some View {
        let shared = resets.available - resets.fableOnly
        if resets.fableOnly > 0 {
            Callout(symbol: "square.stack.3d.up", color: .secondary,
                    text: (shared > 0 ? "\(shared) for the shared limits · " : "")
                        + "\(resets.fableOnly) clear\(resets.fableOnly == 1 ? "s" : "") only the Fable weekly limit")
        }
        if let usable = resets.usableNow, usable < resets.available {
            Callout(symbol: "pause.circle", color: .secondary, text: "\(usable) usable right now")
        }
        if let seen = resets.seenAt, model.now.timeIntervalSince(seen) > 30 * 60 {
            Callout(symbol: "clock", color: .secondary, text: "Count last read \(Format.dayTime(seen))")
        }
        claudeListing
        claudeSpendState
    }

    /// The resets as Anthropic lists them, read when asked: the read shares a rate limit with
    /// TeamClaude's own usage checks.
    @ViewBuilder
    private var claudeListing: some View {
        let status = model.claudeResets[account.id]
        let loading = model.claudeResetsLoading.contains(account.id)
        if let status {
            let fresh = status.isFresh(at: model.now)
            if status.grants.isEmpty {
                Callout(symbol: "tray", color: .secondary, text: "Anthropic lists no reset for this account.")
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(status.grants) { grant in
                    claudeRow(grant, status: status, fresh: fresh)
                }
            }
            .padding(.top, 2)
            HStack(spacing: 6) {
                Text("Read from Anthropic at \(Format.time(status.readAt))" + (fresh ? "" : ", too old to spend from"))
                    .font(.system(size: 10)).foregroundStyle(fresh ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Palette.amber))
                Spacer(minLength: 0)
                if !loading {
                    Button("Read Again") { model.loadClaudeResets(account.id) }
                        .buttonStyle(ActionButtonStyle(compact: true))
                }
            }
        } else if !loading {
            Button("List Resets") { model.loadClaudeResets(account.id) }
                .buttonStyle(ActionButtonStyle())
                .help("Read this account's resets from Anthropic, with the token TeamClaude stores. Spends nothing.")
        }
        if loading {
            QueueNote(state: model.queueState(account.id, .read), sending: "Reading resets from Anthropic…",
                      held: "The read is queued and goes out", stop: "Stop Waiting") {
                model.cancelClaudeCall(account.id, .read)
            }
        } else if let until = model.rateLimitedUntil(account.id, .read) {
            // No read is waiting, but the last one found the limit: say what a new one will do.
            Callout(symbol: "hourglass", color: .secondary,
                    text: "Anthropic limits reads on this account until \(Format.time(until)). A read asked for now "
                        + "waits in the queue until then.")
        }
        if let failure = model.claudeResetsError[account.id], !loading {
            let after = failure.retryAt ?? model.rateLimitedUntil(account.id, .read)
            let retry = after.flatMap { $0 > model.now ? " Try again after \(Format.time($0))." : nil } ?? ""
            Callout(symbol: "exclamationmark.triangle.fill", color: Palette.amber,
                    text: "Could not read the resets: \(failure.message)." + retry)
        }
    }

    private func claudeRow(_ grant: ClaudeResetGrant, status: ClaudeResetStatus, fresh: Bool) -> some View {
        let blocked = status.blocked(grant, now: model.now)
        let count = grant.resetsTotal.map { "\(grant.resetsLeft) of \($0) left" } ?? "\(grant.resetsLeft) left"
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Pill(text: grant.kind.title, color: kindColor(grant.kind))
                    Text(count).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    if let ends = grant.endsAt {
                        Text("expires \(Format.day(ends))").font(.system(size: 10.5)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Clears \(ClaudeResets.limits(grant.clears))" + (grant.isNext ? " · next in line" : ""))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let blocked {
                    Text(blocked).font(.system(size: 10)).foregroundStyle(Palette.amber)
                }
            }
            .help(grant.label ?? "")
            Spacer(minLength: 0)
            if blocked == nil {
                Button("Use…") {
                    model.clearResetPrompt()
                    model.resetArmed = ResetTarget(account: account.id, grant: grant.id)
                }
                .buttonStyle(ActionButtonStyle(compact: true))
                .disabled(!fresh || model.resetPhase == .applying)
                .help(fresh ? "Spend this reset now. Asks first." : "Read the resets again first")
            }
        }
    }

    private func kindColor(_ kind: ClaudeResetGrant.Kind) -> Color {
        switch kind {
        case .weekly: return .accentColor
        case .fable: return Color(hex: "#bf5af2")
        case .session: return Color(hex: "#30d1b2")
        }
    }

    @ViewBuilder
    private var claudeSpendState: some View {
        switch model.resetPhase(for: account.id) {
        case .applying:
            QueueNote(state: model.queueState(account.id, .spend), sending: "Asking Anthropic to reset…",
                      held: "The spend is queued and goes out again, under the same request id,", stop: "Stop Waiting") {
                model.cancelClaudeCall(account.id, .spend)
            }
        case .done(let message):
            Callout(symbol: "checkmark.circle.fill", color: Palette.ok, text: message)
        case .declined(let message):
            Callout(symbol: "info.circle.fill", color: .secondary, text: message)
        case .uncertain(let message):
            Callout(symbol: "exclamationmark.triangle.fill", color: Palette.amber, text: message)
        case .idle:
            if let target = model.resetArmed, target.account == account.id,
               let status = model.claudeResets[account.id],
               let grant = status.grants.first(where: { $0.id == target.grant }) {
                Callout(symbol: "exclamationmark.triangle.fill", color: Palette.amber, text: claudeConfirmation(grant))
                ForEach(status.warnings(grant, now: model.now), id: \.self) { warning in
                    Callout(symbol: "exclamationmark.circle", color: Palette.amber, text: warning)
                }
                HStack(spacing: 8) {
                    Button("Cancel") { model.resetArmed = nil }.buttonStyle(ActionButtonStyle())
                    Button("Spend Reset") { model.applyClaudeReset() }
                        .buttonStyle(ActionButtonStyle(prominent: true, tint: Palette.amber))
                }
            }
        }
    }

    private func claudeConfirmation(_ grant: ClaudeResetGrant) -> String {
        var text = "This spends one \(grant.kind.title) reset to clear \(ClaudeResets.limits(grant.clears)) on "
            + "\(model.identity(account.id).label) now. It cannot be undone."
        let windows = account.windows.compactMap { window in window.used.map { "\(window.title) \(Format.percent($0))" } }
        if !windows.isEmpty { text += " Used so far: " + windows.joined(separator: ", ") + "." }
        return text + " The request goes to Anthropic with the token TeamClaude stores, and TeamClaude sees the "
            + "new limits at its next usage check."
    }

    // MARK: Codex

    @ViewBuilder
    private var codexBody: some View {
        if let grants = resets.grants, !grants.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(grants.enumerated()), id: \.element.id) { index, grant in
                    HStack(spacing: 6) {
                        Image(systemName: index == 0 ? "1.circle.fill" : "circle")
                            .font(.system(size: 10)).foregroundStyle(index == 0 ? Color.accentColor : .secondary)
                        Text(grant.title ?? "Reset").font(.system(size: 11))
                        Spacer(minLength: 0)
                        Text(grant.expiresAt.map { "expires \(Format.day($0))" } ?? "no expiry")
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if resets.available > grants.count {
                Text("and \(resets.available - grants.count) more not listed").font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        redeemControl
    }

    @ViewBuilder
    private var redeemControl: some View {
        switch model.resetPhase(for: account.id) {
        case .applying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Asking Codex to reset…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .done(let message):
            Callout(symbol: "checkmark.circle.fill", color: Palette.ok, text: message)
        case .declined(let message):
            Callout(symbol: "info.circle.fill", color: .secondary, text: message)
            redeemButton
        case .uncertain(let message):
            Callout(symbol: "exclamationmark.triangle.fill", color: Palette.amber, text: message)
            redeemButton
        case .idle:
            if model.resetArmed?.account == account.id {
                Callout(symbol: "exclamationmark.triangle.fill", color: Palette.amber, text: confirmation)
                HStack(spacing: 8) {
                    Button("Cancel") { model.resetArmed = nil }.buttonStyle(ActionButtonStyle())
                    Button("Spend Reset") { Task { await model.applyCodexReset() } }
                        .buttonStyle(ActionButtonStyle(prominent: true, tint: Palette.amber))
                }
            } else {
                redeemButton
            }
        }
    }

    private var redeemButton: some View {
        Button("Use a Reset…") {
            model.clearResetPrompt()
            model.resetArmed = ResetTarget(account: account.id)
        }
        .buttonStyle(ActionButtonStyle())
        .disabled(account.isStale(at: model.now) || model.resetPhase == .applying)
        .help("Clear the Codex limits now by spending one banked reset")
    }

    /// What the spend does, with the reading that says whether it is worth it.
    private var confirmation: String {
        var text = "This spends one reset"
        if let expiry = resets.nextGrant?.expiresAt { text += ", the one that expires \(Format.day(expiry))," }
        text += " to clear the Codex limits now. It cannot be undone."
        let windows = account.windows.compactMap { window in window.used.map { "\(window.title) \(Format.percent($0))" } }
        if !windows.isEmpty { text += " Used so far: " + windows.joined(separator: ", ") + "." }
        if !account.blocked, (account.peak ?? 0) < model.proxy.threshold {
            text += " No limit is reached, so Codex may answer that there is nothing to reset."
        }
        return text
    }
}

/// Where a call to Anthropic stands in the queue: on its way, behind another call, or waiting
/// for a rate limit to clear, with the time it goes out and a way to stop waiting.
struct QueueNote: View {
    var state: APIQueue.State?
    /// Shown while the call is on its way.
    var sending: String
    /// The start of the sentence that says when a held call goes out, such as "The read goes out".
    var held: String
    var stop: String
    var cancel: () -> Void

    var body: some View {
        switch state {
        case .held(let until):
            HStack(alignment: .center, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Callout(symbol: "hourglass", color: Palette.amber,
                            text: "Anthropic rate-limited this account. \(held) at \(Format.time(until)), "
                                + "in \(Format.countdown(until.timeIntervalSince(context.date))).")
                }
                Spacer(minLength: 0)
                Button(stop, action: cancel).buttonStyle(ActionButtonStyle(compact: true)).fixedSize()
            }
        case .queued:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("In line behind another call to Anthropic…").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel", action: cancel).buttonStyle(ActionButtonStyle(compact: true)).fixedSize()
            }
        case .sending, nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(sending).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The queue of calls to Anthropic, in the popover footer: shown only while something is in it.
struct QueueBadge: View {
    var queue: APIQueue.Snapshot

    var body: some View {
        let waiting = queue.entries.filter { $0.state != .sending }.count
        let sending = queue.entries.count - waiting
        HStack(spacing: 4) {
            if sending > 0 {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor)
                Text("Calling Anthropic" + (waiting > 0 ? " · \(waiting) waiting" : ""))
            } else if let release = queue.nextRelease {
                Image(systemName: "hourglass").foregroundStyle(Palette.amber)
                Text("\(waiting) Anthropic call\(waiting == 1 ? "" : "s") waiting · next \(Format.time(release))")
            } else {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
                Text("\(waiting) Anthropic call\(waiting == 1 ? "" : "s") in line")
            }
        }
        .lineLimit(1)
        .help(queue.entries.map { entry in
            switch entry.state {
            case .sending: return "\(entry.label): on its way"
            case .queued: return "\(entry.label): in line"
            case .held(let until): return "\(entry.label): rate-limited, goes out at \(Format.time(until))"
            }
        }.joined(separator: "\n"))
    }
}
