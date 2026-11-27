import SwiftUI
import RunoutCore

/// TeamClaude is missing, being installed, or has no account yet: what happens, and the next step.
struct SetupBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.setupPhase {
        case .installing(let step):
            row(color: .accentColor, title: "Setting up TeamClaude", detail: step + "…") {
                ProgressView().controlSize(.small)
            }
        case .failed where showsAccount:
            // The pool turned out empty: the proxy could not have started, and the account is the next step.
            account
        case .failed(let reason):
            let title: String = model.teamClaudeFound ? "TeamClaude's proxy did not start" : "TeamClaude was not set up"
            row(symbol: "xmark.octagon.fill", color: Palette.red, title: title, detail: reason) {
                button("Try Again", tint: Palette.red) { await model.retrySetup() }
            }
        case .idle:
            if case .missing(let traces) = model.teamClaude {
                missing(traces: traces)
            } else if case .disabled = model.teamClaude {
                EmptyView()
            } else if model.needsAccount {
                account
            }
        }
    }

    @ViewBuilder
    private func missing(traces: Bool) -> some View {
        if model.proxyElsewhere {
            row(symbol: "questionmark.folder.fill", color: Palette.amber, title: "TeamClaude's CLI was not found",
                detail: elsewhere) {
                Button("Edit Config") { model.openConfig() }
                    .buttonStyle(ActionButtonStyle(prominent: true, tint: Palette.amber, compact: true))
                    .fixedSize()
                    .help("Opens the config file, where \"teamclaude\" names the CLI's path.")
            }
        } else if let blocker = model.setupBlocker {
            row(symbol: "shippingbox.fill", color: Palette.amber, title: "TeamClaude is not installed", detail: blocker) {
                button("Check Again", tint: Palette.amber) { await model.installTeamClaude() }
                    .help("Looks for Node again and installs TeamClaude.\nA Node in another folder is set with \"npm\" and \"node\" in the config.")
            }
        } else {
            let detail: String = traces
                ? "Files of another copy are on this Mac. Install it again, or set \"teamclaude\" in the config."
                : "Runout Bar uses TeamClaude to pool and read Claude accounts."
            row(symbol: "shippingbox.fill", color: .accentColor,
                title: traces ? "TeamClaude was not found" : "TeamClaude is not installed", detail: detail) {
                button("Install", tint: .accentColor) { await model.installTeamClaude() }
                    .help(installHelp)
            }
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 7) {
            row(symbol: "person.crop.circle.badge.plus", color: .accentColor, title: "Add a Claude account",
                detail: accountDetail) {
                ReconnectControl(signIn: AppModel.newAccount, tint: .accentColor, prominent: true, title: "Add Account")
            }
            ReconnectStatus(signIn: AppModel.newAccount)
        }
        .padding(9)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
    }

    /// TeamClaude is here and waits for its first account.
    private var showsAccount: Bool { model.teamClaudeFound && !model.setupPhase.busy && model.needsAccount }

    private var installHelp: String {
        let dir: String = model.config.teamclaudeInstallDir
        var text: String = "Installs the latest @karpeleslab/teamclaude with npm into \(dir)\n"
        text += "and links \(model.config.teamclaude) to it. Once it has an account,\n"
        text += "teamclaude service install starts the proxy now and at login."
        return text
    }

    /// A proxy that answers without a CLI on this Mac's usual paths, or a dashboard on another machine.
    private var elsewhere: String {
        let address: String = URL(string: model.config.dashboard).flatMap { url in
            url.host.map { host in url.port.map { "\(host):\($0)" } ?? host }
        } ?? model.config.dashboard
        return "A proxy is set at \(address), but its CLI is in none of the usual folders on this Mac. "
            + "Set \"teamclaude\" in the config to its path."
    }

    private var accountDetail: String {
        model.proxy.up ? "Sign in on claude.ai. Claude Code then runs through the proxy with: \(model.cliCommandName) run"
            : "Sign in on claude.ai. The proxy starts once it has an account."
    }

    private func button(_ title: String, tint: Color, perform: @escaping () async -> Void) -> some View {
        Button(title) { Task { await perform() } }
            .buttonStyle(ActionButtonStyle(prominent: true, tint: tint, compact: true))
            .fixedSize()
    }

    /// One line of the banner. The account state frames two of them itself, so only the others get a frame here.
    @ViewBuilder
    private func row<Trailing: View>(symbol: String? = nil, color: Color, title: String, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        let framed = !showsAccount
        let content = HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(color).font(.system(size: 15)) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing()
        }
        if framed {
            content
                .padding(9)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.25)))
        } else {
            content
        }
    }
}
