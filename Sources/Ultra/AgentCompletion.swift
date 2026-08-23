import AppKit
import Foundation
import UltraDesign
import UltraLayout
import UserNotifications

/// Posts the notifications.
///
/// Authorization is requested the first time the preference is ON and something is worth
/// saying — never at launch. macOS only ever asks once, so spending that prompt on a feature
/// the user has not opted into is spending it badly.
@MainActor
final class AgentCompletionNotifier {
    static let shared = AgentCompletionNotifier()

    private var hasRequestedAuthorization = false
    /// Injectable so tests never touch the real notification centre.
    var deliver: (String, String) -> Void

    private init() {
        deliver = { title, body in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    func notify(title: String, body: String) {
        requestAuthorizationIfNeeded()
        deliver(title, body)
    }

    private func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
