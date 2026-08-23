import Foundation
import UltraCore

/// Projects opened before, newest first.
///
/// Backed by the saved workspaces themselves rather than a separate list, so a project is
/// "recent" exactly when there is something to restore for it. A parallel list would drift
/// the moment a workspace file was quarantined or removed, and offer menu items that open
/// an empty layout.
///
/// The user's explicit order is kept on top of that: opening a project moves it to the
/// front NOW, rather than after the debounced save lands.
@MainActor
enum RecentProjects {
    private static var cached: [String]?
    private static var pinnedOrder: [String] = []
    private static var cleared = false

    static var list: [String] {
        if let cached { return cached }
        // Disk order is by file modification date; anything opened this session is hoisted
        // in front of it, in the order it was opened.
        let onDisk = cleared ? [] : WorkspaceStorage().recentDirectories()
        var out = pinnedOrder
        for path in onDisk where !out.contains(path) { out.append(path) }
        cached = out
        return out
    }

    static func remember(_ directory: String) {
        let path = WorkspaceDocument.canonical(directory)
        pinnedOrder.removeAll { $0 == path }
        pinnedOrder.insert(path, at: 0)
        cleared = false
        cached = nil
    }

    /// Empties the menu for this session. It does NOT delete workspaces: the layouts stay on
    /// disk and the project reopens exactly as it was. Clearing a menu is a privacy gesture
    /// about what is displayed, not a request to throw work away.
    static func clear() {
        pinnedOrder.removeAll()
        cleared = true
        cached = nil
    }

    static func invalidate() { cached = nil }
}
