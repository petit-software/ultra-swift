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
                     theme: TerminalTheme? = nil,
                     restore: Bool = true) -> LayoutStore {
        let document = restore ? storage.loadAll().first : nil
        let records: [PaneID: PaneRecord] = document.map { document in
            Dictionary(uniqueKeysWithValues: document.panes.compactMap { key, value in
                PaneID(uuidString: key).map { ($0, value) }
            })
        } ?? [:]

        // One id for the workspace, its store, and its agent socket — they must agree.
        let workspaceID = document?.id ?? UUID()

        let theme = theme ?? Preferences.resolvedTheme()
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
            currentDirectory: { Registry.workingDirectory(fallback: root) },
            openInEditor: { url in
                guard let store = Registry.stores.values.first else { return }
                openEditor(on: url, in: store)
            }),
            restoring: records)

        let store = LayoutStore(tree: document?.tree ?? LayoutTree(single: PaneID()),
                                theme: theme,
                                workspaceID: workspaceID,
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
        factory.onAgentActivityChange = { _ in updateSleepGuard() }

        // The agent control channel. Scoped to this workspace: its socket lives in the
        // project, and every path an agent names is resolved against this root.
        let channel = AgentChannel(socketURL: .init(fileURLWithPath: AgentChannel
            .defaultSocketURL(for: workspaceID).path)) { request in
            // The socket serves off its own queue; anything that touches panes has to be on
            // the main actor, and the agent is told what happened either way.
            MainActor.assumeIsolated {
                perform(request, in: root)
            }
        }
        if channel.start() {
            factory.agentSocketPath = channel.socketURL.path
        }
        Registry.channels[store.workspaceID] = channel
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
        @MainActor static var channels: [UUID: AgentChannel] = [:]

        /// Where a new tile should point: the focused pane's directory when it has one,
        /// else any pane's, else the workspace's own. Pane records carry the LIVE cwd —
        /// a shell reports its directory as it changes — so this follows `cd`.
        @MainActor static func workingDirectory(fallback: URL) -> URL {
            for store in stores.values {
                // The focused pane when it is itself a shell — that is the one the user is
                // working in. Otherwise the FIRST shell in the layout, which is the pane a
                // project is usually opened into. A tile has no directory of its own to
                // offer, so a focused tile falls through rather than answering.
                let focused = store.tree.focused
                if let record = store.surfaces.records[focused],
                   record.kind == .shell, let cwd = record.cwd {
                    return URL(fileURLWithPath: cwd)
                }
                for paneID in store.tree.paneIDs {
                    if let record = store.surfaces.records[paneID],
                       record.kind == .shell, let cwd = record.cwd {
                        return URL(fileURLWithPath: cwd)
                    }
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

    /// Open a new editor pane on a specific file.
    static func openEditor(on file: URL, in store: LayoutStore) {
        guard let edge = newPaneEdge(in: store) else { NSSound.beep(); return }
        Registry.tiles[store.workspaceID]?.stage(file: file)
        stageTile(.editor, for: store)
        if !store.split(edge: edge) {
            stageTile(nil, for: store)
            Registry.tiles[store.workspaceID]?.stage(file: nil)
        }
    }

    /// Open a new shell pane, optionally running an agent.
    static func openShell(agent: AgentDefinition? = nil, in store: LayoutStore) {
        guard let edge = newPaneEdge(in: store) else { NSSound.beep(); return }
        stageAgent(agent, for: store)
        if !store.split(edge: edge) { stageAgent(nil, for: store) }
    }

    /// Carry out one agent request, or say why not.
    @MainActor
    static func perform(_ request: AgentRequest, in root: URL) -> AgentResponse {
        let resolved: ResolvedAgentRequest
        do {
            resolved = try request.resolve(in: root)
        } catch let error as AgentRequestError {
            return .failure(error.message)
        } catch {
            return .failure("\(error)")
        }
        guard let store = Registry.stores.values.first else {
            return .failure("no window open")
        }
        switch resolved.verb {
        case .open:
            openEditor(on: resolved.url, in: store)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([resolved.url])
        }
        return .success
    }

    /// Total agents running across every tab, not just one — the machine is kept awake for
    /// the app as a whole.
    static func updateSleepGuard() {
        SleepGuard.shared.agentsRunningChanged(
            to: Registry.factories.values.reduce(0) { $0 + $1.runningAgentCount })
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
    /// The same symbol the pane wears in its header, so the menu and the icon agree.
    let symbol: String
    var id: PaneRecord.Kind { kind }

    static let all: [PaneKind] = [
        PaneKind(kind: .shell, title: "Shell", symbol: "apple.terminal"),
        PaneKind(kind: .fileTree, title: "File Tree", symbol: "folder"),
        PaneKind(kind: .editor, title: "Editor", symbol: "doc.text"),
        PaneKind(kind: .todo, title: "Todo", symbol: "checklist"),
        PaneKind(kind: .git, title: "Git", symbol: "arrow.trianglehead.branch"),
        PaneKind(kind: .ports, title: "Ports", symbol: "network"),
        PaneKind(kind: .resources, title: "Resources", symbol: "gauge.with.needle"),
        PaneKind(kind: .context, title: "Context", symbol: "paperclip"),
    ]

    /// Handed to the canvas so a pane's own icon can offer the list.
    static var choices: [PaneKindChoice] {
        all.map { PaneKindChoice(kind: $0.kind, title: $0.title, symbol: $0.symbol) }
    }
}
