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
        case .failed(let reason):
            row(symbol: "xmark.octagon.fill", color: Palette.red, title: "TeamClaude was not set up", detail: reason) {
                button("Try Again", tint: Palette.red) {
                    if model.teamClaudeFound { await model.installProxyService() } else { await model.installTeamClaude() }
                }
            }
        case .idle:
            if case .missing(let traces) = model.teamClaude {
                missing(traces: traces)
            } else if model.needsAccount {
                account
            }
        }
    }

    @ViewBuilder
    private func missing(traces: Bool) -> some View {
        if let blocker = model.setupBlocker {
            row(symbol: "shippingbox.fill", color: Palette.amber, title: "TeamClaude is not installed", detail: blocker) {
                button("Check Again", tint: Palette.amber) { await model.installTeamClaude() }
                    .help("Looks for Node again and installs TeamClaude.\nA Node in another folder is set with \"npm\" and \"node\" in the config.")
            }
        } else {
            let detail: String = traces
                ? "Files of another copy are on this Mac. Install it again, or set \"teamclaude\" in the config."
                : "Runout Bar reads Claude usage from this local proxy."
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
                detail: "Sign in on claude.ai. Claude Code then runs through the proxy with: teamclaude run") {
                ReconnectControl(signIn: AppModel.newAccount, tint: .accentColor, prominent: true, title: "Add Account")
            }
            ReconnectStatus(signIn: AppModel.newAccount)
        }
        .padding(9)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
    }

    private var installHelp: String {
        let dir: String = model.config.teamclaudeInstallDir
        var text: String = "Installs the latest @karpeleslab/teamclaude with npm into \(dir),\n"
        text += "links \(model.config.teamclaude) to it, and runs teamclaude service install,\n"
        text += "which starts the proxy now and at login."
        return text
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
        let framed = !(model.setupPhase == .idle && model.needsAccount)
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
