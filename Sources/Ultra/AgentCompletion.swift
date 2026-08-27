import AppKit
import Foundation
import UltraDesign
import UltraLayout
import UserNotifications

/// Posts the notifications, and takes them back once they have been read.
///
/// Authorization is requested the first time the preference is ON and something is worth
/// saying — never at launch. macOS only ever asks once, so spending that prompt on a feature
/// the user has not opted into is spending it badly.
@MainActor
final class AgentCompletionNotifier {
    static let shared = AgentCompletionNotifier()

    /// Every notification this app posts carries it.
    ///
    /// What makes "clear the ones the user has now seen" possible without
    /// `removeAllDeliveredNotifications`, which would also take away anything posted later
    /// for some other reason. It survives a relaunch because it is part of the identifier
    /// macOS stored, not state this process is holding.
    ///
    /// `nonisolated` because it is read from the notification centre's own callback queue,
    /// which is not the main actor. A `let` String is Sendable, so there is nothing to race.
    nonisolated private static let identifierPrefix = "agent.completion."

    /// `UNUserNotificationCenter.current()` TRAPS when there is no bundle identifier, and an
    /// SPM executable started with `swift run Ultra` has none — the same fact that makes
    /// `UltraApp.init` ask for an activation policy by hand. Every route to the notification
    /// centre goes through this, so a debug run stays a debug run instead of a crash.
    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private var hasRequestedAuthorization = false
    private var activationObserver: NSObjectProtocol?

    /// Injectable so tests never touch the real notification centre.
    var deliver: (String, String) -> Void
    /// Injectable for the same reason as `deliver`.
    var clearDelivered: () -> Void

    private init() {
        deliver = { title, body in
            guard Self.canNotify else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: Self.identifierPrefix + UUID().uuidString,
                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        clearDelivered = {
            guard Self.canNotify else { return }
            // `current()` is asked for again inside the callback rather than captured:
            // `UNUserNotificationCenter` is not Sendable, and the callback arrives on the
            // centre's own queue. It is a singleton, so this is the same object either way.
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let ours = delivered.map(\.request.identifier)
                    .filter { $0.hasPrefix(Self.identifierPrefix) }
                guard !ours.isEmpty else { return }
                UNUserNotificationCenter.current()
                    .removeDeliveredNotifications(withIdentifiers: ours)
            }
        }
    }

    func notify(title: String, body: String) {
        requestAuthorizationIfNeeded()
        deliver(title, body)
    }

    /// Take the notifications back whenever the user comes to look.
    ///
    /// A delivered notification sits in Notification Centre until something removes it, and
    /// macOS never does that on an app's behalf — so "an agent finished" stayed on screen
    /// long after it had been read, and a few of them turned a helpful nudge into a list to
    /// dismiss by hand. The message is only true until it is seen, and opening the app IS
    /// seeing it: that is the same event the app already treats as "the user is watching"
    /// when deciding not to notify in the first place.
    ///
    /// Started at launch rather than on the first notification. One delivered before a quit
    /// is still there at the next launch, and that stale one is the most worth clearing.
    func startClearingWhenActive() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearDelivered() }
            }
        // Usually ALREADY active by the time this runs: the window's task fires after
        // `adoptWindow()` has activated the app, so the launch's own activation has been and
        // gone. Waiting for the next one would leave a backlog sitting through the whole
        // first session.
        if NSApp?.isActive == true { clearDelivered() }
    }

    private func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization, Self.canNotify else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
