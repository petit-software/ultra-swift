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
                // Trailing space: sends are meant to COMPOSE at the prompt — two paths in a
                // row must not arrive as one glued-together argument.
                let separated = text.hasSuffix(" ") ? text : text + " "
                factory.inject(separated, into: target, submit: false)
            },
            revealInFinder: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            shellPIDs: { [weak factory] in
                Set(factory?.shells.values.compactMap(\.processID) ?? [])
            },
            currentDirectory: { Registry.workingDirectory(fallback: root) }),
            restoring: records)

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

        /// Where a new tile should point: the focused pane's directory when it has one,
        /// else any pane's, else the workspace's own. Pane records carry the LIVE cwd —
        /// a shell reports its directory as it changes — so this follows `cd`.
        @MainActor static func workingDirectory(fallback: URL) -> URL {
            for store in stores.values {
                if let cwd = store.surfaces.records[store.tree.focused]?.cwd {
                    return URL(fileURLWithPath: cwd)
                }
                if let cwd = store.tree.paneIDs.compactMap({ store.surfaces.records[$0]?.cwd }).first {
                    return URL(fileURLWithPath: cwd)
                }
            }
            return fallback
        }

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

    /// Which way a new pane should open, or nil when there is no room for one.
    ///
    /// Always splitting right means "New Pane" stops working as soon as the focused pane is
    /// narrow — the split is refused for leaving an unusable half, and a beep is all the user
    /// gets. Splitting the LONGER axis keeps panes closer to square and keeps room available
    /// for longer; the remaining edges are tried before giving up.
    static func newPaneEdge(in store: LayoutStore) -> Edge? {
        let focused = store.tree.focused
        let frame = store.layoutResult.frames[focused]
        let widerThanTall = frame.map { $0.width >= $0.height } ?? true
        let order: [Edge] = widerThanTall ? [.right, .bottom, .left, .top]
                                          : [.bottom, .right, .top, .left]
        return order.first {
            canSplit(store.tree, pane: focused, edge: $0,
                     in: store.canvasBounds, metrics: store.metrics)
        }
    }

    /// Whether a new pane would fit at all. Menus dim their "New …" entries on this rather
    /// than offering a command that can only beep.
    static func canOpenNewPane(in store: LayoutStore) -> Bool {
        newPaneEdge(in: store) != nil
    }

    /// Open a new pane holding a tile.
    ///
    /// The kind is staged BEFORE the split, because the factory is consulted during it. So a
    /// refused split has to clear the staging again, or the next successful split silently
    /// becomes a tile the user asked for minutes ago and had already given up on.
    static func openTile(_ kind: PaneRecord.Kind, in store: LayoutStore) {
        guard let edge = newPaneEdge(in: store) else { NSSound.beep(); return }
        stageTile(kind, for: store)
        if !store.split(edge: edge) { stageTile(nil, for: store) }
    }

    /// Open a new shell pane, optionally running an agent.
    static func openShell(agent: AgentDefinition? = nil, in store: LayoutStore) {
        guard let edge = newPaneEdge(in: store) else { NSSound.beep(); return }
        stageAgent(agent, for: store)
        if !store.split(edge: edge) { stageAgent(nil, for: store) }
    }

    /// Turn an existing pane into a different kind, in place.
    ///
    /// The pane keeps its id, its position and its size; only its contents change. A shell
    /// being converted away loses its PTY, which is why the menu says "Change" rather than
    /// offering it as a view toggle.
    static func convert(_ paneID: PaneID, to kind: PaneRecord.Kind, in store: LayoutStore) {
        guard store.surfaces.surfaceRecord(for: paneID).kind != kind else { return }
        Registry.tiles[store.workspaceID]?.forget(paneID)
        Registry.tiles[store.workspaceID]?.stage(TileFactory.supported.contains(kind) ? kind : nil)
        store.replaceContent(of: paneID)
    }

    /// Every kind a pane can be, in menu order.
    static var paneKinds: [PaneKind] { PaneKind.all }

    /// Make the next new pane a tile of this kind rather than a shell. Pass nil to clear a
    /// staging that never got used — a refused split must not leave one armed.
    static func stageTile(_ kind: PaneRecord.Kind?, for store: LayoutStore) {
        Registry.tiles[store.workspaceID]?.stage(kind)
    }

    /// Agents that are actually installed, probed through a login shell.
    static func availableAgents() -> [AgentDefinition] {
        AgentDefinition.builtIns.filter { ShellLauncher.isAvailable($0.binary) }
    }
}


/// Every kind a pane can be, in menu order.
///
/// Nonisolated on purpose: the command registry is built at file scope, outside the main
/// actor, and a main-actor list cannot be read from there.
struct PaneKind: Identifiable, Sendable {
    let kind: PaneRecord.Kind
    let title: String
    var id: PaneRecord.Kind { kind }

    static let all: [PaneKind] = [
        PaneKind(kind: .shell, title: "Shell"),
        PaneKind(kind: .fileTree, title: "File Tree"),
        PaneKind(kind: .todo, title: "Todo"),
        PaneKind(kind: .git, title: "Git"),
        PaneKind(kind: .ports, title: "Ports"),
        PaneKind(kind: .resources, title: "Resources"),
        PaneKind(kind: .context, title: "Context"),
    ]
}
