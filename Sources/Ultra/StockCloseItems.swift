import AppKit

/// Takes AppKit's own File ▸ Close (⌘W) and Close All (⌥⌘W) out of the main menu.
///
/// On macOS 27 AppKit puts both into the File menu itself, outside SwiftUI's commands: plain
/// items sent to the first responder (`performClose:` and `closeAll:`, no target), where
/// SwiftUI's own Close used to stand. `CommandGroup(replacing: .saveItem)` no longer removes
/// them — the group's own items, Close Window among them, were the ones that went missing —
/// and SwiftUI yields a duplicate shortcut to the item that was there first. So ⌘W lost its
/// place on Pane ▸ Close Pane, which was left showing no key, and closed the WINDOW: on the
/// one window most people have, that is every session in it at once, and the app with them.
/// Found by walking `NSApp.mainMenu` in a running build, not by reading the code, which
/// says what it always said.
///
/// Taken out rather than re-keyed. Closing a window is Close Window (⇧⌘W) and Close All
/// Windows (⌥⌘W), both ours; leaving AppKit's beside them would be the same verb twice.
/// Watched for, not removed once: the menu is SwiftUI's to rebuild and AppKit's to fill in,
/// and either may happen after launch.
@MainActor
enum StockCloseItems {
    private static let actions: Set<Selector> = [
        #selector(NSWindow.performClose(_:)), NSSelectorFromString("closeAll:"),
    ]
    private static var observer: (any NSObjectProtocol)?

    static func start() {
        remove()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { _ in
                // Next turn: a menu being filled in is not one to take items out of.
                DispatchQueue.main.async { MainActor.assumeIsolated { remove() } }
            }
    }

    /// The stock items, wherever in the menu bar's menus they have been put. Only the ones
    /// with no target: SwiftUI's own items all carry one.
    static func remove() {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            for item in menu.items
            where item.target == nil && item.action.map(actions.contains) == true {
                menu.removeItem(item)
            }
        }
    }
}
