import SwiftUI
import RunoutCore

struct ProxyTab: View {
    @Environment(AppModel.self) private var model
    static let probeChoices = [0, 60, 120, 300, 600]

    var body: some View {
        VStack(spacing: 10) {
            statusCard
            // Without TeamClaude there is nothing to update, restart or open.
            if model.teamClaudeFound { updateCard }
            if !model.signIns.isEmpty { SignInsCard() }
            if model.proxy.up {
                routingCard
                healthCard
            }
            if model.teamClaudeFound { actions }
        }
    }

    private var actions: some View {
        Group {
            HStack(spacing: 6) {
                Button { Task { await model.restartProxy() } } label: {
                    Label("Restart", systemImage: "arrow.clockwise.circle")
                }
                .help(restartHelp)
                Button { model.openLog() } label: { Label("Log", systemImage: "doc.text") }
                    .help("Open the proxy log in Console")
                Button { model.openDashboard() } label: { Label("Dashboard", systemImage: "safari") }
                    .help("Open \(model.config.dashboard) in the browser")
            }
            .buttonStyle(ActionButtonStyle())
        }
    }

    private var statusCard: some View {
        let proxy = model.proxy
        return Card {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 18))
                    .foregroundStyle(proxy.up ? Palette.ok : Palette.red)
                    .frame(width: 32, height: 32)
                    .background((proxy.up ? Palette.ok : Palette.red).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(proxy.up ? "TeamClaude is running"
                         : model.teamClaudeFound ? "TeamClaude is not responding" : "TeamClaude is not installed")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(statusDetail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var restartHelp: String {
        let sessions = model.proxy.activeSessions
        return "Restart the TeamClaude proxy. It takes a few seconds"
            + (sessions > 0 ? " and interrupts \(sessions) active session\(sessions == 1 ? "" : "s")." : ".")
    }

    private var statusDetail: String {
        let proxy = model.proxy
        guard model.teamClaudeFound else { return "Looked for it at \(model.config.teamclaude)" }
        guard proxy.up else { return proxy.error ?? "No answer from teamclaude status" }
        var parts: [String] = []
        if let version = proxy.version { parts.append("v\(version)") }
        if let uptime = proxy.uptime { parts.append("up \(Format.duration(uptime))") }
        if let pid = proxy.pid { parts.append("pid \(pid)") }
        return parts.joined(separator: " · ")
    }

    private var updateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: model.updateAvailable ? "arrow.down.circle.fill" : "checkmark.seal.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(model.updateAvailable ? Color.accentColor : Palette.ok)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateTitle).font(.system(size: 12.5, weight: .semibold))
                        Text(updateDetail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    updateButton
                }
                if model.updateArmed, let latest = model.latestTeamClaude {
                    HStack(spacing: 6) {
                        Text(armedWarning(latest)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Cancel") { model.updateArmed = false }.buttonStyle(ActionButtonStyle()).fixedSize()
                        Button("Install") { Task { await model.updateTeamClaude() } }
                            .buttonStyle(ActionButtonStyle(prominent: true)).fixedSize()
                    }
                }
                switch model.updatePhase {
                case .installing, .restarting, .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(phaseText).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Callout(symbol: "xmark.octagon.fill", color: Palette.red, text: message)
                case .done(let version):
                    Callout(symbol: "checkmark.circle.fill", color: Palette.ok, text: "Updated to \(version); the proxy is running it")
                case .idle:
                    EmptyView()
                }
                if model.restartPending, model.updatePhase == .idle {
                    Callout(symbol: "arrow.clockwise.circle", color: Palette.amber,
                            text: "A newer version is installed; restart the proxy to run it")
                }
            }
        }
    }

    private var updateTitle: String {
        if model.updateAvailable, let latest = model.latestTeamClaude { return "TeamClaude \(latest) is available" }
        if case .done = model.updatePhase { return "TeamClaude is up to date" }
        return model.latestTeamClaude == nil && model.updateError != nil ? "Update check failed" : "TeamClaude is up to date"
    }

    private var updateDetail: String {
        var parts = ["Installed \(model.installedTeamClaude ?? "unknown")"]
        if let checked = model.updateCheckedAt { parts.append("checked \(Format.time(checked))") }
        if let error = model.updateError { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private func armedWarning(_ latest: String) -> String {
        let sessions = model.proxy.activeSessions
        let interrupted = sessions > 0 ? " and interrupts \(sessions) active session\(sessions == 1 ? "" : "s")" : ""
        return "Installs \(latest) with npm, then restarts the proxy. The restart takes a few seconds\(interrupted)."
    }

    private var phaseText: String {
        switch model.updatePhase {
        case .checking: return "Checking npm…"
        case .installing: return "Installing with npm…"
        case .restarting: return "Restarting the proxy…"
        default: return ""
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        if model.updateAvailable {
            Button("Update…") { model.updateArmed = true }
                .buttonStyle(ActionButtonStyle(prominent: true))
                .fixedSize()
                .disabled(model.updatePhase.busy || model.updateArmed)
        } else {
            Button("Check") { Task { await model.checkForUpdates(force: true) } }
                .buttonStyle(ActionButtonStyle())
                .fixedSize()
                .disabled(model.updatePhase.busy)
                .help("Ask npm for the latest TeamClaude release")
        }
    }

    private var routingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("New requests go to").sectionTitle()
                HStack(spacing: 6) {
                    ForEach(model.accounts.filter { $0.provider == .claude }) { account in
                        let identity = model.identity(account.id)
                        Button {
                            if !account.routing { Task { await model.route(to: account.id) } }
                        } label: {
                            HStack(spacing: 5) {
                                Badge(identity: identity, size: 16)
                                Text(identity.label).lineLimit(1)
                            }
                        }
                        .buttonStyle(ActionButtonStyle(prominent: account.routing, tint: Color(hex: identity.color)))
                        .help(account.routing ? "New requests go to \(identity.label)"
                                : "Send new requests to \(identity.label) (teamclaude switch)")
                    }
                }
                Text("Usage check").sectionTitle().padding(.top, 2)
                Picker("Usage check", selection: Binding(
                    get: { model.proxy.probeInterval },
                    set: { value in Task { await model.setProbe(value) } })) {
                    ForEach(Self.probeChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : Format.duration(TimeInterval(seconds))).tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("How often TeamClaude checks each account's usage (teamclaude probe)")
            }
        }
    }

    private var healthCard: some View {
        let proxy = model.proxy
        return Card {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("waveform.path.ecg", "Event loop",
                    "\(Int(proxy.eventLoopLagMs ?? 0)) ms lag · max \(Int(proxy.eventLoopMaxLagMs ?? 0)) ms"
                        + (proxy.stallCount > 0 ? " · \(proxy.stallCount) stalls" : ""),
                    color: (proxy.eventLoopLagMs ?? 0) > 500 ? Palette.amber : nil)
                row("network", "Upstream", "\(proxy.upstreamActive) active · \(proxy.upstreamQueued) queued",
                    color: proxy.upstreamQueued > 0 ? Palette.amber : nil)
                if let sync = proxy.callbackLastSync {
                    row("arrow.triangle.2.circlepath", "Account sync",
                        proxy.callbackError ?? "synced \(RelativeDateTimeFormatter().localizedString(for: sync, relativeTo: model.now))",
                        color: proxy.callbackError != nil ? Palette.amber : nil,
                        help: "Last sync \(Format.day(sync)) at \(Format.timeSeconds(sync))"
                            + (proxy.callbackError.map { "\n\($0)" } ?? ""))
                }
                if proxy.signInNeeded > 0 {
                    row("person.crop.circle.badge.exclamationmark", "Sign-in", "\(proxy.signInNeeded) account(s) need it",
                        color: Palette.amber)
                }
            }
            .font(.system(size: 11))
        }
    }

    private func row(_ symbol: String, _ title: String, _ value: String, color: Color? = nil,
                     help: String = "") -> some View {
        GridRow {
            Image(systemName: symbol).foregroundStyle(color ?? .secondary).frame(width: 14)
            Text(title).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color ?? .primary).lineLimit(1).help(help)
        }
    }
}
