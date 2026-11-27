import SwiftUI
import RunoutCore

struct SourcesTab: View {
    @Environment(AppModel.self) private var model
    static let probeChoices = [0, 60, 120, 300, 600]
    @State private var showHealth = false
    @State private var editingProxyKey = false
    @State private var proxyKeyDraft = ""

    private var teamClaudeSignIns: [SignIn] {
        model.signIns.filter { $0.holder == .teamclaude || $0.holder == .teamclaudeCodex }
    }

    var body: some View {
        VStack(spacing: 10) {
            if !model.teamClaudeDisabled {
                teamClaudeSection
            } else {
                Card(padding: 9) {
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("TeamClaude disabled").font(.system(size: 12, weight: .semibold))
                            Text("\"teamclaude\": \"\" in config.json — Anthropic pooling is off.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            directCLIsCard
        }
    }

    @ViewBuilder
    private var teamClaudeSection: some View {
        statusCard
        if model.teamClaudeFound, model.updateAvailable || model.updatePhase.busy || model.restartPending {
            updateCard
        } else if model.teamClaudeFound {
            compactUpdateCard
        }
        if model.proxy.up {
            routingCard
        }
        if !teamClaudeSignIns.isEmpty {
            SignInsCard(
                title: "TeamClaude sign-ins",
                subtitle: "OAuth · ~30d lifetime",
                signIns: teamClaudeSignIns
            )
        }
        if model.proxy.up, model.proxyAuthRequired || model.hasSavedProxyApiKey || editingProxyKey {
            proxyKeyCard
        }
        if model.proxy.up {
            healthCard
        }
        if model.teamClaudeFound { actions }
    }

    private var directCLIsCard: some View {
        let codexSignIn = model.signIns.first { $0.holder == .codex }
        let googleSignIn = model.signIns.first { $0.holder == .google }
        let codexAccount = model.accounts.first { $0.provider == .codex }
        let googleGroups = model.accounts.filter { $0.provider == .google && !$0.windows.isEmpty }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Direct CLIs").sectionTitle()
                    Spacer()
                    Text("not routed through TeamClaude").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                directRow(
                    title: "OpenAI Codex",
                    badge: codexAccount?.plan,
                    statusColor: directColor(available: model.codexAvailable,
                                             disabled: model.codexConfiguredDisabled,
                                             accounts: codexAccount.map { [$0] } ?? [],
                                             signIn: codexSignIn),
                    detail: codexDetail(account: codexAccount),
                    signIn: codexSignIn
                )
                Divider()
                directRow(
                    title: "Google AI",
                    badge: googleGroups.isEmpty ? nil : "\(googleGroups.count) groups",
                    statusColor: directColor(available: model.googleAvailable,
                                             disabled: model.googleConfiguredDisabled,
                                             accounts: model.accounts.filter { $0.provider == .google },
                                             signIn: googleSignIn),
                    detail: googleDetail(groups: googleGroups),
                    signIn: googleSignIn
                )
            }
        }
    }

    @ViewBuilder
    private func directRow(title: String, badge: String?, statusColor: Color, detail: String,
                           signIn: SignIn?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12, weight: .semibold))
                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                Spacer(minLength: 0)
                if let signIn {
                    ReconnectControl(signIn: signIn, link: true)
                }
            }
            Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            if let signIn, signIn.stage(at: model.now) > .ok {
                Text(signIn.headline(now: model.now))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(signIn.stage(at: model.now).color)
            } else if let signIn {
                Text(signIn.headline(now: model.now))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func directColor(available: Bool, disabled: Bool, accounts: [AccountSnapshot],
                             signIn: SignIn?) -> Color {
        if disabled || !available { return .secondary }
        if signIn?.stage(at: model.now) == .lapsed { return Palette.red }
        if accounts.contains(where: { $0.isStale(at: model.now) || $0.error != nil }) { return Palette.amber }
        return Palette.ok
    }

    private func codexDetail(account: AccountSnapshot?) -> String {
        if model.codexConfiguredDisabled { return "Hidden in config (\"codex\": \"\")" }
        if !model.codexAvailable { return "CLI not found (codex)" }
        if let err = account?.error, account?.windows.isEmpty ?? true { return err }
        return "codex app-server · checked every 2m"
    }

    private func googleDetail(groups: [AccountSnapshot]) -> String {
        if model.googleConfiguredDisabled { return "Hidden in config (\"agy\": \"\")" }
        if !model.googleAvailable { return "CLI not found (agy)" }
        let googleErr = model.accounts.first { $0.provider == .google }?.error
        if groups.isEmpty, let googleErr { return googleErr }
        let names = groups.compactMap(\.title).joined(separator: ", ")
        return "agy CLI · checked every 5m" + (names.isEmpty ? "" : " · \(names)")
    }

    private var actions: some View {
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
                    Text(statusTitle).font(.system(size: 12.5, weight: .semibold))
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

    private var statusTitle: String {
        if model.proxy.up { return "TeamClaude proxy is running" }
        if !model.teamClaudeFound { return "TeamClaude is not installed" }
        return model.needsAccount ? "TeamClaude has no account yet" : "TeamClaude is not responding"
    }

    private var statusDetail: String {
        let proxy = model.proxy
        guard model.teamClaudeFound else { return "Looked for it at \(model.config.teamclaude)" }
        if !proxy.up, model.needsAccount { return "The proxy starts once an account is added." }
        guard proxy.up else { return proxy.error ?? "No answer from teamclaude status" }
        var parts: [String] = []
        if let version = proxy.version { parts.append("v\(version)") }
        if let uptime = proxy.uptime { parts.append("up \(Format.duration(uptime))") }
        let claudeCount = model.accounts.count { $0.provider == .claude }
        if claudeCount > 0 {
            parts.append("pools \(claudeCount) Claude account\(claudeCount == 1 ? "" : "s")")
        }
        parts.append("switch \(Int(proxy.threshold))%")
        return parts.joined(separator: " · ")
    }

    private var compactUpdateCard: some View {
        Card(padding: 9) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.ok).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(updateTitle).font(.system(size: 11.5, weight: .semibold))
                    Text(updateDetail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                updateButton
            }
        }
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
        if model.updateAvailable, !model.updatesInPlace {
            // A copy this app did not install is updated where it lives, by TeamClaude's own updater.
            Button("Copy command") { model.copy("\(model.cliCommandName) update") }
                .buttonStyle(ActionButtonStyle(prominent: true))
                .fixedSize()
                .help(elsewhereHelp)
        } else if model.updateAvailable {
            Button("Update…") { model.updateArmed = true }
                .buttonStyle(ActionButtonStyle(prominent: true))
                .fixedSize()
                .disabled(model.updatePhase.busy || model.updateArmed)
        } else {
            Button("Check") { Task { await model.checkForUpdates(force: true) } }
                .buttonStyle(ActionButtonStyle())
                .fixedSize()
                .disabled(model.updatePhase.busy)
                .help("Ask npm for the latest \(model.teamClaudePackage) release")
        }
    }

    private var elsewhereHelp: String {
        let dir: String = model.config.teamclaudeInstallDir
        return "This copy is not in \(dir), so Runout Bar does not update it.\n"
            + "It updates itself with: \(model.cliCommandName) update"
    }

    private var routingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Route new Claude requests to").sectionTitle()
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
                        .help(account.routing ? "New Claude requests go to \(identity.label)"
                                : "Send new Claude requests to \(identity.label) (\(model.cliCommandName) switch)")
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
                .help("How often TeamClaude checks each account's usage (\(model.cliCommandName) probe)")
            }
        }
    }

    @ViewBuilder
    private var proxyKeyCard: some View {
        if model.proxyAuthRequired || editingProxyKey {
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(model.proxyAuthRequired ? Palette.amber : Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.proxyAuthRequired ? "Proxy API key needed" : "Update proxy API key")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Saved locally (0600) in ~/.config/runout-bar/proxy-key")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        SecureField("Proxy API key (tc-...)", text: $proxyKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .onSubmit { submitProxyKey() }
                        if editingProxyKey && !model.proxyAuthRequired {
                            Button("Cancel") {
                                proxyKeyDraft = ""
                                editingProxyKey = false
                            }
                            .buttonStyle(ActionButtonStyle(compact: true))
                            .fixedSize()
                        }
                        Button("Save") { submitProxyKey() }
                            .buttonStyle(ActionButtonStyle(prominent: true, compact: true))
                            .fixedSize()
                            .disabled(proxyKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let keyErr = model.proxyKeyError {
                        Callout(symbol: "exclamationmark.triangle.fill", color: Palette.amber, text: keyErr)
                    }
                }
            }
        } else if model.hasSavedProxyApiKey {
            Card(padding: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Proxy API key saved").font(.system(size: 11.5, weight: .semibold))
                        Text("~/.config/runout-bar/proxy-key (0600)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Change") {
                        proxyKeyDraft = ""
                        editingProxyKey = true
                    }
                    .buttonStyle(ActionButtonStyle(compact: true))
                    .fixedSize()
                    Button("Clear") { model.clearProxyApiKey() }
                        .buttonStyle(ActionButtonStyle(compact: true))
                        .fixedSize()
                }
            }
        }
    }

    private func submitProxyKey() {
        let trimmed = proxyKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        proxyKeyDraft = ""
        editingProxyKey = false
        model.saveProxyApiKey(trimmed)
    }

    private var healthCard: some View {
        let proxy = model.proxy
        return Card(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showHealth.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Proxy health").sectionTitle()
                        Spacer()
                        Text("\(Int(proxy.eventLoopLagMs ?? 0)) ms lag · \(proxy.upstreamActive) active")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showHealth ? 180 : 0))
                    }
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 6))

                if showHealth {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        if let pid = proxy.pid {
                            row("number", "Process", "pid \(pid)")
                        }
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
