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
                .scrollIndicators(.never)
                .frame(height: min(contentHeight, 620))
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
                    case .proxy: ProxyTab()
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
                    if tab == .proxy, model.updateAvailable || !model.proxy.up {
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
                Button { model.selectedAccount = nil; model.tab = .proxy } label: {
                    HStack(spacing: 6) {
                        Circle().fill(model.proxy.up ? Palette.ok : Palette.red).frame(width: 6, height: 6)
                        Text(model.proxy.up ? "TeamClaude \(model.proxy.version ?? "")" : "TeamClaude not responding")
                    }
                }
                .buttonStyle(LinkButtonStyle())
                .help(proxyHelp)
                Spacer(minLength: 0)
                if !model.apiQueue.entries.isEmpty {
                    QueueBadge(queue: model.apiQueue)
                } else if let last = model.lastRefresh {
                    Text("Updated \(Format.time(last))")
                        .help("Last read \(Format.day(last)) at \(Format.timeSeconds(last)). "
                            + "Readings refresh every minute.")
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
    /// The proxy's vital signs, for the footer.
    fileprivate var proxyHelp: String {
        let proxy = model.proxy
        guard proxy.up else {
            return (proxy.error ?? "No answer from teamclaude status") + "\nClick for the Proxy tab."
        }
        var parts: [String] = []
        if let uptime = proxy.uptime { parts.append("up \(Format.duration(uptime))") }
        if let pid = proxy.pid { parts.append("pid \(pid)") }
        parts.append("\(proxy.activeSessions) active session\(proxy.activeSessions == 1 ? "" : "s")")
        return parts.joined(separator: " · ") + "\nClick for the Proxy tab."
    }
}

/// Things that need attention, shown above every tab.
struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.summary
        VStack(spacing: 6) {
            if !model.proxy.up, model.lastRefresh != nil {
                banner(symbol: "bolt.horizontal.circle.fill", color: Palette.red, title: "TeamClaude proxy is not responding",
                       detail: model.proxy.error, action: "Restart") { Task { await model.restartProxy() } }
            }
            ForEach(model.signInsDue) { SignInBanner(signIn: $0) }
            if summary.exhausted {
                let when = summary.freeAgainAt.map { " until \(Format.dayTime($0))" } ?? ""
                banner(symbol: "hourglass", color: Palette.red, title: "No Claude capacity left\(when)", detail: nil,
                       action: nil, perform: nil)
            }
            if model.updateAvailable, model.tab != .proxy, let latest = model.latestTeamClaude {
                banner(symbol: "arrow.down.circle.fill", color: .accentColor, title: "TeamClaude \(latest) is available",
                       detail: "You have \(model.installedTeamClaude ?? "?")", action: "Review") { model.tab = .proxy }
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
            Picker("Numbers show", selection: $model.numberMode) {
                ForEach(NumberMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Pool Run-Out Time", isOn: $model.showRunOut)
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
