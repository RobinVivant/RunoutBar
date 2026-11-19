import Foundation
import RunoutCore
import UserNotifications

/// Native notifications when the app runs as a bundle and is allowed to post;
/// `osascript` otherwise.
@MainActor
final class Notifier {
    private var denied = false
    /// The key a notification carries its sign-in id under, so a click on it can open that sign-in.
    nonisolated static let signInKey = "signIn"

    func post(_ notices: [Notice]) {
        for notice in notices { post(notice) }
    }

    private func post(_ notice: Notice) {
        guard Bundle.main.bundleIdentifier != nil, !denied else {
            Self.osascript(notice)
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                denied = true
                Self.osascript(notice)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            if let signIn = notice.signIn { content.userInfo = [Self.signInKey: signIn] }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func osascript(_ notice: Notice) {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = "display notification \(quoted(notice.body)) with title \(quoted(notice.title))"
        Task.detached { _ = try? await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10) }
    }
}
