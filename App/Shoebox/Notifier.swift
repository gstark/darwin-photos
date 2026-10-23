import ShoeboxCore
import Foundation
import UserNotifications

/// Sends a notification when a backup ends, and when photos wait for an
/// iCloud sign-in.
@MainActor
final class Notifier: NSObject {
    enum Level: String, CaseIterable, Identifiable {
        case all
        case problems
        case off

        var id: Self { self }

        var title: String {
            switch self {
            case .all: "Every backup"
            case .problems: "Only problems"
            case .off: "Off"
            }
        }
    }

    static let levelKey = "notifications"
    nonisolated private static let signInCategory = "sign-in"
    private static let signInAction = "sign-in"
    private static let lastSignInNoticeKey = "lastSignInNotice"

    private let center = UNUserNotificationCenter.current()
    /// Called when the user clicks Sign In on a notification.
    private var onSignIn: (@MainActor () -> Void)?

    var level: Level {
        Level(rawValue: UserDefaults.standard.string(forKey: Self.levelKey) ?? "") ?? .problems
    }

    func start(onSignIn: @escaping @MainActor () -> Void) {
        self.onSignIn = onSignIn
        center.delegate = self
        let signIn = UNNotificationAction(identifier: Self.signInAction, title: "Sign In", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.signInCategory, actions: [signIn], intentIdentifiers: []),
        ])
    }

    func notify(_ run: RunRecord) async {
        guard level != .off else { return }
        var notices: [UNMutableNotificationContent] = []
        switch run.outcome {
        case .succeeded where run.failed > 0:
            notices.append(content("Backup finished with problems", "\(run.stored.formatted()) new, \(run.failed.formatted()) failed. Show Failures lists them."))
        case .succeeded where level == .all:
            notices.append(content("Backup complete", run.stored == 0 ? "No new photos." : "\(run.stored.formatted()) new photos backed up."))
        case .failed(let reason):
            notices.append(content("Backup failed", reason))
        default:
            break
        }
        // At most one sign-in reminder each day.
        let lastNotice = UserDefaults.standard.object(forKey: Self.lastSignInNoticeKey) as? Date ?? .distantPast
        if run.waitingForSignIn > 0, !Calendar.current.isDateInToday(lastNotice) {
            let notice = content("Sign in to iCloud", "\(run.waitingForSignIn.formatted()) photos need an iCloud sign-in to back up.")
            notice.categoryIdentifier = Self.signInCategory
            notices.append(notice)
            UserDefaults.standard.set(Date(), forKey: Self.lastSignInNoticeKey)
        }
        guard !notices.isEmpty,
              (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        else { return }
        for notice in notices {
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: notice, trigger: nil))
        }
    }

    private func content(_ title: String, _ body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        return content
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let category = response.notification.request.content.categoryIdentifier
        guard category == Self.signInCategory else { return }
        await MainActor.run { onSignIn?() }
    }

    /// Shows notifications while the app is active, for example when the
    /// menu is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
