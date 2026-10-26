import AppKit
import Foundation
import UltraDesign
import UltraLayout
import UserNotifications

/// Posts the notifications, and takes them back once they have been read.
///
/// Authorization is requested when the preference is switched ON, and at launch when it
/// already is — never before the user has opted in. macOS only ever asks once, so spending
/// that prompt on a feature the user has not opted into is spending it badly.
///
/// It used to be requested later still: by the first notification, which came only after an
/// agent had worked for half a minute while the user was away. Someone who switched the
/// setting on and watched for the prompt never saw one, and when it did come the
/// notification that raised it had already been posted and refused, because a request made
/// while the answer is still "not determined" is not delivered. The prompt arrived with
/// nothing behind it.
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

    /// The session a notification is about, carried in its `userInfo` so a click on it can
    /// go there. Read on the notification centre's queue, hence `nonisolated`.
    nonisolated static let workspaceKey = "workspaceID"
    nonisolated static let paneKey = "paneID"

    private var activationObserver: NSObjectProtocol?
    /// Held for as long as the app runs: the centre keeps only a weak reference.
    private let clicks = NotificationClicks()

    /// Injectable so tests never touch the real notification centre.
    var deliver: (String, String, UUID?, PaneID?) -> Void
    /// Injectable for the same reason as `deliver`.
    var clearDelivered: () -> Void

    private init() {
        deliver = { title, body, workspaceID, paneID in
            guard Self.canNotify else { return }
            // Posted from inside the authorization callback, not beside it. Once the user has
            // answered, this completes at once with the stored answer; before they have, it
            // puts the question up and waits, and the notification follows the answer
            // instead of being refused while it is pending. The content is built in the
            // callback too: a `UNNotificationRequest` is not Sendable, three strings are.
            let workspace = workspaceID?.uuidString
            let pane = paneID?.uuidString
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    if let workspace {
                        content.userInfo = [Self.workspaceKey: workspace]
                        if let pane { content.userInfo[Self.paneKey] = pane }
                    }
                    let request = UNNotificationRequest(
                        identifier: Self.identifierPrefix + UUID().uuidString,
                        content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request)
                }
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

    func notify(title: String, body: String, workspaceID: UUID? = nil, paneID: PaneID? = nil) {
        deliver(title, body, workspaceID, paneID)
    }

    /// Put the system's permission prompt up, if it has not been answered yet.
    ///
    /// Called when the setting is switched on — the moment the footer under it promises the
    /// question — and at launch when it is already on, for everyone who switched it on
    /// before this asked. Once answered, macOS completes at once without asking again, so
    /// calling it on every launch costs nothing.
    func requestAuthorization() {
        guard Self.canNotify else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        // The delegate is what makes a click go somewhere, and what shows a banner while
        // the app is active but has no window on screen — the one "not watching" case
        // where macOS would otherwise swallow it. Set once, here, which runs before the
        // first notification can be posted.
        if Self.canNotify { UNUserNotificationCenter.current().delegate = clicks }
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
}

/// What happens when a notification is clicked: the session it names comes to the front.
///
/// The centre calls these on its own queue, so the work hops to the main actor once the
/// `userInfo` it needs has been read — the response itself is not Sendable.
private final class NotificationClicks: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completion: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let workspaceID = (info[AgentCompletionNotifier.workspaceKey] as? String).flatMap(UUID.init(uuidString:))
        let paneID = (info[AgentCompletionNotifier.paneKey] as? String).flatMap(PaneID.init(uuidString:))
        Task { @MainActor in
            NSApplication.shared.activate()
            // The pane, where it is: on the Agents overview if that is up, else in its
            // session, raised. The session alone when the notification named no pane.
            if let paneID {
                AgentsOverview.shared.reveal(paneID, in: workspaceID)
            } else if let workspaceID {
                _ = SessionList.raise(workspaceID: workspaceID)
            }
        }
        // Answered here, on the centre's queue: the handler is not Sendable, and the hop
        // above has what it needs already.
        completion()
    }

    /// Shown even while the app is frontmost. The policy has already decided the user is
    /// not watching — the app can be active with every window closed — and a banner
    /// suppressed here would be a decision made twice, the second time wrongly.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound])
    }
}
