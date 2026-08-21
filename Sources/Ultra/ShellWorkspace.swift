import AppKit
import Foundation
import UltraCanvas
import UltraCore
import UltraDesign
import UltraLayout
import UltraTerminal
import UltraTiles

/// Builds a workspace whose panes are real shells.
///
/// This is the only place `UltraCanvas` and `UltraTerminal` meet: the canvas asks for
/// content by `PaneID`, the terminal layer supplies it. Neither imports the other.
@MainActor
enum ShellWorkspace {

    /// - Parameter restore: whether to adopt the saved layout. False for a new TAB, which
    ///   is new work — restoring into it would clone the panes already on screen.
    static func make(storage: WorkspaceStorage,
                     directory: String,
                     theme: TerminalTheme = .dark,
                     restore: Bool = true) -> LayoutStore {
        let document = restore ? storage.loadAll().first : nil
        let records: [PaneID: PaneRecord] = document.map { document in
            Dictionary(uniqueKeysWithValues: document.panes.compactMap { key, value in
                PaneID(uuidString: key).map { ($0, value) }
            })
        } ?? [:]

        let factory = ShellPaneFactory(theme: theme, defaultDirectory: directory,
                                       restoring: records)

        // Non-shell tiles. `injectIntoShell` is the shared "send to shell" verb: it targets
        // the focused pane when that pane IS a shell, and otherwise the first shell in the
        // layout — a file tree cannot type into itself.
        let root = URL(fileURLWithPath: directory)
        let tiles = TileFactory(context: TileContext(
            root: root,
            injectIntoShell: { [weak factory] text in
                guard let factory, let target = Registry.injectionTarget else { return }
                factory.inject(text, into: target, submit: false)
            },
            revealInFinder: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }), restoring: records)

        let store = LayoutStore(tree: document?.tree ?? LayoutTree(single: PaneID()),
                                theme: theme,
                                workspaceID: document?.id ?? UUID(),
                                storage: storage) { paneID in
            // Tiles first: the factory returns nil for anything it does not own, and the
            // shell factory picks up everything else. The canvas never learns the difference.
            if let tile = tiles.makeContent(for: paneID) {
                return PaneContent(view: tile.view, record: tile.record)
            }
            let content = factory.makeContent(for: paneID)
            return PaneContent(view: content.view, record: content.record)
        }

        store.workspaceTitle = document?.title
            ?? URL(fileURLWithPath: directory).lastPathComponent
        store.workspaceSubtitle = document?.subtitle ?? ShellPaneFactory.abbreviate(directory)
        store.windowFrame = document?.windowFrame?.rect

        // Closing a pane is the only thing that kills its PTY.
        store.surfaces.onRelease = { [weak factory, weak tiles] paneID in
            factory?.release(paneID)
            tiles?.release(paneID)
        }
        // Once geometry stops moving, every shell gets its authoritative size.
        store.onGeometrySettled = { [weak factory] in factory?.commitResize() }
        // A shell renames its own pane as it runs; the header follows.
        factory.onDescriptorChange = { [weak store] paneID, record in
            store?.surfaces.updateRecord(record, for: paneID)
            store?.persist()
        }

        // Keyed by workspace, not a singleton: with tabs there are several live factories
        // at once and a menu command must reach the one belonging to the focused tab.
        Registry.factories[store.workspaceID] = factory
        Registry.tiles[store.workspaceID] = tiles
        Registry.stores[store.workspaceID] = store
        return store
    }

    /// The live factory, so menu commands can reach the shells.
    enum Registry {
        @MainActor static var factories: [UUID: ShellPaneFactory] = [:]
        @MainActor static var tiles: [UUID: TileFactory] = [:]
        @MainActor static var stores: [UUID: LayoutStore] = [:]

        /// The pane a tile's "send to shell" should type into: the focused pane when it is
        /// itself a shell, otherwise the first shell in the layout. Nil when the workspace
        /// holds no shell at all, in which case the verb is a no-op rather than a guess.
        @MainActor static var injectionTarget: PaneID? {
            for (id, store) in stores {
                guard let factory = factories[id] else { continue }
                let focused = store.tree.focused
                if factory.shells[focused] != nil { return focused }
                if let any = store.tree.paneIDs.first(where: { factory.shells[$0] != nil }) {
                    return any
                }
            }
            return nil
        }
    }

    /// Launch the next new pane as an agent rather than a plain shell.
    static func stageAgent(_ agent: AgentDefinition?, for store: LayoutStore) {
        Registry.factories[store.workspaceID]?.stageAgent(agent)
    }

    /// Make the next new pane a tile of this kind rather than a shell.
    static func stageTile(_ kind: PaneRecord.Kind, for store: LayoutStore) {
        Registry.tiles[store.workspaceID]?.stage(kind)
    }

    /// Agents that are actually installed, probed through a login shell.
    static func availableAgents() -> [AgentDefinition] {
        AgentDefinition.builtIns.filter { ShellLauncher.isAvailable($0.binary) }
    }
}
