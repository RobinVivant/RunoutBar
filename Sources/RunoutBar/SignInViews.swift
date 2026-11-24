import SwiftUI
import RunoutCore

extension SignIn.Stage {
    var color: Color {
        switch self {
        case .ok: return Palette.ok
        case .soon, .urgent: return Palette.amber
        case .lapsed: return Palette.red
        }
    }
}

/// One sign-in that is near its end, refused, or being renewed: what happens, and the way back.
struct SignInBanner: View {
    @Environment(AppModel.self) private var model
    var signIn: SignIn

    var body: some View {
        let stage = signIn.stage(at: model.now)
        let color = stage.color
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: stage == .ok ? "checkmark.seal.fill" : "key.fill").foregroundStyle(color)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    // Days ahead, one line is enough; the rest is in the tooltip.
                    if stage != .soon {
                        Text(signIn.explanation(now: model.now)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .help(signIn.explanation(now: model.now))
                Spacer(minLength: 0)
                ReconnectControl(signIn: signIn, tint: color, prominent: stage > .ok)
            }
            ReconnectStatus(signIn: signIn)
        }
        .padding(9)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.25)))
    }

    private var title: String { "\(model.signInLabel(signIn)): \(signIn.headline(now: model.now))" }
}

/// The button that renews a sign-in, or stops a renewal that waits for the browser.
struct ReconnectControl: View {
    @Environment(AppModel.self) private var model
    var signIn: SignIn
    var tint: Color = .accentColor
    var prominent = false
    /// Drawn as a text link, for a row that is not asking for attention.
    var link = false
    var title: String?

    private var label: String { title ?? (signIn.failure?.code == "signed_out" ? "Sign In" : "Reconnect") }

    var body: some View {
        if model.reconnectPhase(for: signIn) == .waiting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                styled(Button("Cancel") { model.cancelReconnect() })
                    .help("Stop waiting for the sign-in. Nothing changes.")
            }
            .fixedSize()
        } else if signIn.manual {
            styled(Button("Copy command") { model.copy(signIn.commandLine) })
                .fixedSize()
                .help("This sign-in is renewed in a terminal, with a code pasted from the browser:\n\(signIn.commandLine)")
        } else {
            styled(Button(label) { Task { await model.reconnect(signIn) } })
                .fixedSize()
                .disabled(model.reconnectPhase == .waiting)
                .help(help)
        }
    }

    @ViewBuilder
    private func styled(_ button: Button<Text>) -> some View {
        if link {
            button.buttonStyle(LinkButtonStyle()).font(.system(size: 10.5, weight: .medium))
        } else {
            button.buttonStyle(ActionButtonStyle(prominent: prominent, tint: tint, compact: true))
        }
    }

    private var help: String {
        let site: String = model.signInSite(signIn)
        let who: String = model.signInIdentity(signIn).map { " as \($0)" } ?? ""
        if signIn.id == AppModel.newAccount.id {
            return "Opens \(site) in the browser to sign in (\(signIn.commandLine)).\n"
                + "The account the browser is signed in to is added to the proxy."
        }
        if signIn.holder == .google {
            return "Opens \(site) in the browser to sign in with Google.\n"
                + "Returns automatically once you approve — no code to paste."
        }
        var text: String = "Opens \(site) in the browser to sign in again (\(signIn.commandLine)).\n"
        text += "Be signed in there\(who) first: the login renews the account the browser is signed in to."
        if signIn.holder == .teamclaude || signIn.holder == .teamclaudeCodex {
            text += "\nThe proxy takes the new sign-in without a restart."
        }
        return text
    }
}

/// Where a renewal stands, or how the last one ended.
struct ReconnectStatus: View {
    @Environment(AppModel.self) private var model
    var signIn: SignIn

    var body: some View {
        switch model.reconnectPhase(for: signIn) {
        case .idle:
            EmptyView()
        case .waiting:
            Callout(symbol: "safari", color: .secondary, text: waiting)
        case .done(let text):
            dismissable(Callout(symbol: "checkmark.circle.fill", color: Palette.ok, text: text))
        case .failed(let text):
            dismissable(Callout(symbol: "xmark.octagon.fill", color: Palette.red, text: text))
        }
    }

    private var waiting: String {
        let who: String = model.signInIdentity(signIn).map { " as \($0)" } ?? ""
        return "Waiting for the sign-in on \(model.signInSite(signIn))\(who). It can take a few minutes."
    }

    private func dismissable(_ callout: Callout) -> some View {
        HStack(alignment: .top, spacing: 6) {
            callout
            Spacer(minLength: 0)
            Button { model.clearReconnect() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .help("Dismiss")
        }
    }
}

/// A group of sign-ins on one card, for the Sources tab: when each ends, and a way to renew it ahead of time.
struct SignInsCard: View {
    @Environment(AppModel.self) private var model
    var title = "Sign-ins"
    var subtitle = "each one ends a fixed time after its login"
    var signIns: [SignIn]?

    var body: some View {
        let items = signIns ?? model.signIns
        Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(title).sectionTitle()
                    Spacer()
                    Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                ForEach(items) { signIn in
                    let stage = signIn.stage(at: model.now)
                    HStack(spacing: 8) {
                        Circle().fill(stage.color).frame(width: 7, height: 7)
                        Text(model.signInLabel(signIn)).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Text(signIn.headline(now: model.now)).font(.system(size: 10.5)).monospacedDigit()
                            .foregroundStyle(stage == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(stage.color))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        ReconnectControl(signIn: signIn, link: true)
                    }
                    .help(rowHelp(signIn))
                }
            }
        }
    }

    private func rowHelp(_ signIn: SignIn) -> String {
        let name: String
        switch signIn.holder {
        case .codex: name = "The Codex CLI's login"
        case .google: name = "The Antigravity CLI's Google login"
        case .teamclaude, .teamclaudeCodex: name = signIn.account
        }
        return "\(name)\n\(signIn.explanation(now: model.now))"
    }
}
