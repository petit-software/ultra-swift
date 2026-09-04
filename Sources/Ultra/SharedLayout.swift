import AppKit
import UltraCanvas
import UltraCore
import UltraLayout
import UltraTiles

/// One project's arrangement of panes, made the DEFAULT, or given to other projects.
///
/// Three verbs, one mechanism. "Set as Default" saves the arrangement; a project opened
/// for the first time takes it (`ShellWorkspace.defaultDocument`), and "Use Default
/// Layout" puts a project back on it. "Apply to All Projects" hands one project's
/// arrangement to every other. All three go through `adopt(_:into:)` for a live session
/// and `adoptingLayout(of:)` for a document on disk, so there is one answer to "what does
/// it mean to give a project a layout".
///
/// The transform itself is `WorkspaceDocument.adoptingLayout(of:)` in UltraCore, which is
/// pure and tested. This is the part that knows where projects LIVE: some are on screen in
/// this or another window, with shells running, and the rest are documents on disk.
@MainActor
enum SharedLayout {

    // MARK: - Default

    /// Remember `source`'s arrangement as the one new projects start with.
    static func setDefault(from source: LayoutStore) {
        guard let storage = source.storage else { return }
        try? storage.saveDefaultLayout(source.document)
    }

    static func hasDefault(for store: LayoutStore) -> Bool {
        store.storage?.hasDefaultLayout ?? false
    }

    /// Ask, then put this project back on the default arrangement.
    static func resetToDefault(_ store: LayoutStore) {
        guard let template = store.storage?.loadDefaultLayout() else { return }
        guard confirm("Use the default layout for this project?",
                      "Its panes are replaced with the default arrangement. Shells in this "
                      + "project are restarted, and this cannot be undone.",
                      button: "Use") else { return }
        adopt(template, into: store)
    }

    // MARK: - Every project

    /// Ask, then apply `source`'s arrangement to every other project Ultra knows about.
    ///
    /// Both kinds of project get it — the live ones and the documents on disk — because a
    /// saved document that is not rewritten would be restored over the new arrangement the
    /// next time that project is opened.
    static func applyToAllProjects(from source: LayoutStore) {
        guard let storage = source.storage, source.workspaceDirectory != nil else { return }
        let template = source.document

        let live = ShellWorkspace.Registry.stores.values.filter {
            $0.workspaceID != source.workspaceID && $0.workspaceDirectory != nil
        }
        let liveDirectories = Set(live.compactMap { $0.workspaceDirectory }
            .map(WorkspaceDocument.canonical))
        let saved = storage.loadAll().filter { document in
            guard let directory = document.directory, document.id != source.workspaceID
            else { return false }
            return !liveDirectories.contains(directory)
        }

        let count = live.count + saved.count
        guard count > 0 else {
            inform("No other projects to apply this layout to.",
                   "A project appears here once it has been opened in Ultra.")
            return
        }
        var detail = "Each project gets the same panes in the same positions, pointed at "
            + "its own folder. Their current layouts are replaced and cannot be undone."
        if live.count > 0 {
            detail += live.count == 1
                ? "\n\nOne of them is open now: its shells will be restarted."
                : "\n\n\(live.count) of them are open now: their shells will be restarted."
        }
        guard confirm(count == 1 ? "Apply this layout to 1 other project?"
                                 : "Apply this layout to \(count) other projects?",
                      detail, button: "Apply") else { return }

        for store in live { adopt(template, into: store) }
        for document in saved {
            try? storage.saveNow(document.adoptingLayout(of: template))
        }
    }

    /// Give a LIVE workspace the arrangement: its factories learn the new panes, then the
    /// store swaps its tree and the canvas builds them.
    ///
    /// Records go to the factories BEFORE the tree changes. The canvas asks for a surface
    /// the moment a pane id appears in the tree, and a factory asked about an id it has no
    /// record for builds a plain shell.
    private static func adopt(_ template: WorkspaceDocument, into store: LayoutStore) {
        let document = store.document.adoptingLayout(of: template)
        var records: [PaneID: PaneRecord] = [:]
        for paneID in document.tree.paneIDs {
            if let record = document.record(for: paneID) { records[paneID] = record }
        }
        let id = store.workspaceID
        ShellWorkspace.Registry.factories[id]?
            .adopt(records: records.filter { $0.value.kind == .shell })
        ShellWorkspace.Registry.tiles[id]?
            .adopt(records: records.filter { TileFactory.supported.contains($0.value.kind) })
        store.adopt(tree: document.tree)
    }

    // MARK: - Dialogs

    /// Says what will happen before it happens: every verb here rewrites a layout the user
    /// arranged by hand, and there is no undo for it.
    private static func confirm(_ message: String, _ detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func inform(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
