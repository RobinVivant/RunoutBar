import SwiftUI
import RunoutCore

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    /// Off when rendering snapshots, where a scroll view would clip.
    var scrolls = true
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedAccount == nil {
                header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            }
            if scrolls {
                ScrollView(.vertical) {
                    content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(contentHeight, maxPopoverHeight))
            } else {
                content
            }
            footer
        }
        .frame(width: 384)
        .animation(.snappy(duration: 0.25), value: model.selectedAccount)
    }

    private var content: some View {
        Group {
            if let id = model.selectedAccount, model.account(id) != nil {
                AccountDetailView(accountID: id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 10) {
                    Banners()
                    switch model.tab {
                    case .usage: UsageTab()
                    case .activity: ActivityTab()
                    case .sources: SourcesTab()
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Picker("View", selection: $model.tab) {
                ForEach(Tab.allCases) { tab in
                    if tab == .sources, model.sourcesNeedAttention {
                        Text("\(tab.rawValue) •").tag(tab)
                    } else {
                        Text(tab.rawValue).tag(tab)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            Spacer(minLength: 0)
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.refreshing ? 360 : 0))
                    .animation(model.refreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: model.refreshing)
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh now" + (model.lastRefresh.map { " · last read \(Format.timeSeconds($0))" } ?? ""))
            SettingsMenu()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let message = model.actionMessage {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                Text(message)
            } else if let error = model.configError {
                Button { model.openConfig() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.amber)
                        Text(error).lineLimit(1)
                    }
                }
                .buttonStyle(LinkButtonStyle())
                .help(error + "\nClick to open the config file.")
            } else {
                Button { model.selectedAccount = nil; model.tab = .sources } label: {
                    HStack(spacing: 8) {
                        ForEach(sourceDots, id: \.label) { item in
                            HStack(spacing: 4) {
                                Circle().fill(item.color).frame(width: 6, height: 6)
                                Text(item.label).lineLimit(1)
                            }
                        }
                    }
                }
                .buttonStyle(LinkButtonStyle())
                .help(sourcesHelp)
                Spacer(minLength: 0)
                if !model.apiQueue.entries.isEmpty {
                    QueueBadge(queue: model.apiQueue)
                } else if let last = model.lastRefresh {
                    Text("Updated \(Format.time(last))")
                        .help(refreshTooltip(last: last))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }
}

extension PopoverView {
    fileprivate var maxPopoverHeight: CGFloat {
        min(740, max(620, (NSScreen.main?.visibleFrame.height ?? 900) - 140))
    }

    fileprivate var sourceDots: [(label: String, color: Color)] {
        var items: [(String, Color)] = []
        if !model.teamClaudeDisabled {
            let color: Color
            if model.proxy.up {
                let tcDue = model.signIns.contains {
                    ($0.holder == .teamclaude || $0.holder == .teamclaudeCodex) && $0.stage(at: model.now) > .ok
                }
                color = tcDue ? Palette.amber : Palette.ok
            } else if !model.teamClaudeFound || model.needsAccount {
                color = Palette.amber
            } else {
                color = Palette.red
            }
            let label = model.proxy.up ? "TC \(model.proxy.version ?? "")".trimmingCharacters(in: .whitespaces)
                : !model.teamClaudeFound ? "No TC" : model.needsAccount ? "TC setup" : "TC down"
            items.append((label, color))
        }
        if model.codexAvailable || model.accounts.contains(where: { $0.provider == .codex }) {
            let codexAccounts = model.accounts.filter { $0.provider == .codex }
            let lapsed = model.signIns.first { $0.holder == .codex }?.stage(at: model.now) == .lapsed
            let stale = codexAccounts.contains { $0.isStale(at: model.now) || $0.error != nil }
            items.append(("Codex", lapsed ? Palette.red : stale ? Palette.amber : Palette.ok))
        }
        if model.googleAvailable || model.accounts.contains(where: { $0.provider == .google }) {
            let googleAccounts = model.accounts.filter { $0.provider == .google }
            let lapsed = model.signIns.first { $0.holder == .google }?.stage(at: model.now) == .lapsed
            let stale = googleAccounts.contains { $0.isStale(at: model.now) || $0.error != nil }
            items.append(("Google", lapsed ? Palette.red : stale ? Palette.amber : Palette.ok))
        }
        if items.isEmpty {
            items.append(("No sources", .secondary))
        }
        return items
    }

    fileprivate func refreshTooltip(last: Date) -> String {
        var parts: [String] = []
        if !model.teamClaudeDisabled { parts.append("Claude every minute") }
        if model.accounts.contains(where: { $0.provider == .codex }) { parts.append("Codex every 2 minutes") }
        if model.accounts.contains(where: { $0.provider == .google }) { parts.append("Google AI every 5 minutes") }
        let schedule = parts.isEmpty ? "" : "\nRefreshes: " + parts.joined(separator: ", ") + "."
        return "Last read \(Format.day(last)) at \(Format.timeSeconds(last))." + schedule
    }

    fileprivate var sourcesHelp: String {
        var lines: [String] = []
        if !model.teamClaudeDisabled {
            let proxy = model.proxy
            if proxy.up {
                var parts: [String] = ["TeamClaude \(proxy.version ?? "")"]
                if let uptime = proxy.uptime { parts.append("up \(Format.duration(uptime))") }
                parts.append("\(proxy.activeSessions) active session\(proxy.activeSessions == 1 ? "" : "s")")
                lines.append(parts.joined(separator: " · "))
            } else if !model.teamClaudeFound {
                lines.append("TeamClaude is not installed")
            } else if model.needsAccount {
                lines.append("TeamClaude has no account yet")
            } else {
                lines.append("TeamClaude: \(proxy.error ?? "not responding")")
            }
        }
        if model.codexAvailable || model.accounts.contains(where: { $0.provider == .codex }) {
            let err = model.accounts.first { $0.provider == .codex }?.error
            lines.append("Codex CLI: " + (err ?? "connected"))
        }
        if model.googleAvailable || model.accounts.contains(where: { $0.provider == .google }) {
            let err = model.accounts.first { $0.provider == .google }?.error
            lines.append("Google AI (agy): " + (err ?? "connected"))
        }
        return (lines + ["Click for the Sources tab."]).joined(separator: "\n")
    }
}

/// Things that need attention, shown above every tab.
struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.summary
        VStack(spacing: 6) {
            if !model.teamClaudeDisabled && (model.setupPhase != .idle || !model.teamClaudeFound || model.needsAccount) {
                SetupBanner()
            } else if !model.teamClaudeDisabled, !model.proxy.up, model.lastRefresh != nil {
                if model.proxyServiceInstalled {
                    banner(symbol: "bolt.horizontal.circle.fill", color: Palette.red,
                           title: "TeamClaude proxy is not responding",
                           detail: model.proxy.error, action: "Restart") { Task { await model.restartProxy() } }
                } else {
                    // Nothing starts a proxy that has no LaunchAgent, and there is nothing to restart.
                    banner(symbol: "bolt.horizontal.circle.fill", color: Palette.red, title: "TeamClaude is not running",
                           detail: "Nothing starts it at login yet.", action: "Start at Login") {
                        Task { await model.installProxyService() }
                    }
                }
            }
            ForEach(model.signInsDue) { SignInBanner(signIn: $0) }
            if summary.exhausted {
                let when = summary.freeAgainAt.map { " until \(Format.dayTime($0))" } ?? ""
                banner(symbol: "hourglass", color: Palette.red, title: "No Claude capacity left\(when)", detail: nil,
                       action: nil, perform: nil)
            }
            if !model.teamClaudeDisabled, model.updateAvailable, model.tab != .sources,
               let latest = model.latestTeamClaude {
                banner(symbol: "arrow.down.circle.fill", color: .accentColor, title: "TeamClaude \(latest) is available",
                       detail: "You have \(model.installedTeamClaude ?? "?")", action: "Review") { model.tab = .sources }
            }
        }
    }

    private func banner(symbol: String, color: Color, title: String, detail: String?, action: String?,
                        perform: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if let action, let perform {
                Button(action, action: perform).buttonStyle(ActionButtonStyle(prominent: true, tint: color)).fixedSize()
            }
        }
        .padding(9)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.25)))
    }
}

struct SettingsMenu: View {
    @Environment(AppModel.self) private var model
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Menu bar shows", selection: $model.menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
            }
            Picker("Menu bar bars", selection: $model.menuBarGrouping) {
                ForEach(MenuBarGrouping.allCases) { Text($0.title).tag($0) }
            }
            Picker("Numbers show", selection: $model.numberMode) {
                ForEach(NumberMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Menu bar run-out", selection: $model.menuBarRunOutMode) {
                ForEach(MenuBarRunOutMode.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle("Notifications", isOn: $model.notificationsOn)
            Button("Send Test Notification") { model.sendTestNotification() }
            Toggle("Open at Login", isOn: Binding(get: { LoginItem.isEnabled },
                                                 set: { loginError = LoginItem.set($0) }))
            Divider()
            Button("Edit Accounts…") { model.openConfig() }
            Button("Reload Accounts") { model.reloadConfig() }
            Divider()
            Button("Quit Runout Bar") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(3)
        .modifier(HoverHighlight(cornerRadius: 6))
        .help(loginError ?? "Settings")
    }
}
