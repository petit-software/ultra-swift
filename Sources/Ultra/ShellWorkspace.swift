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
        // BY PATH, not "whichever document is first on disk" — that stood in for this while
        // there was only ever one project, and silently gave every project the same layout.
        let document = restore ? storage.load(directory: directory) : nil
        let records: [PaneID: PaneRecord] = document.map { document in
            Dictionary(uniqueKeysWithValues: document.panes.compactMap { key, value in
                PaneID(uuidString: key).map { ($0, value) }
            })
        } ?? [:]

        // One id for the workspace, its store, and its agent socket — they must agree.
        let workspaceID = document?.id ?? UUID()

        let theme = theme ?? Preferences.resolvedTheme()
        // History is restored only for a workspace that is itself being restored. A fresh
        // window opening on a project it has never opened has no panes to match, so there is
        // nothing to hand back and nothing to prune.
        let factory = ShellPaneFactory(theme: theme, defaultDirectory: directory,
                                       restoring: records,
                                       scrollback: ScrollbackStore())

        // Non-shell tiles. `injectIntoShell` is the shared "send to shell" verb: it targets
        // the shell the user was last working in — a file tree cannot type into itself.
        //
        // Scoped to THIS workspace, by id. These closures used to read whichever store the
        // Registry dictionary happened to hand back first, so with two tabs open a tile
        // could type into a shell in the other one.
        let root = URL(fileURLWithPath: directory)
        let tiles = TileFactory(context: TileContext(
            root: root,
            injectIntoShell: { [weak factory] text in
                guard let factory,
                      let target = Registry.injectionTarget(in: workspaceID) else { return }
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
            currentDirectory: { Registry.workingDirectory(in: workspaceID, fallback: root) },
            openInEditor: { request in
                guard let store = Registry.stores[workspaceID] else { return }
                showInEditor(request, in: store)
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
        store.workspaceDirectory = directory
        store.windowFrame = document?.windowFrame?.rect

        // A tile was pointed at a different folder: rebuild it there. See
        // `TileFactory.retarget`.
        tiles.onRootChange = { [weak store] paneID, _ in
            // Next turn of the run loop, because the retarget almost always comes from a
            // click INSIDE the tile being replaced, and tearing a view down while it is
            // still handling its own event is how a click ends up delivered to a
            // deallocated view.
            DispatchQueue.main.async {
                guard let store else { return }
                store.replaceContent(of: paneID)
                // Build it now rather than waiting for the layout pass, so the pane header
                // and the tab say the new folder immediately.
                _ = store.surfaces.surfaceRecord(for: paneID)
                store.refreshWindowTitle()
                store.persist()
            }
        }

        // An editor switched tabs: the header should name the file it is now showing. A
        // record change, NOT a rebuild — `onRootChange` tears the tile down and builds it
        // again, which for an editor would throw away every open tab to relabel one.
        tiles.onRecordChange = { [weak store] paneID, record in
            guard let store else { return }
            store.surfaces.updateRecord(record, for: paneID)
            if store.tree.focused == paneID { store.refreshWindowTitle() }
            store.persist()
        }

        // Closing a pane is the only thing that kills its PTY.
        store.surfaces.onRelease = { [weak factory, weak tiles] paneID in
            factory?.release(paneID)
            tiles?.release(paneID)
        }
        // What a pane can become, offered from the pane's own icon. The canvas has no
        // idea what a "Todo" is — it lays out rectangles — so the list and the verb both
        // come from here.
        store.setPaneKinds({ PaneKind.choices }) { [weak store] paneID, kind in
            guard let store else { return }
            convert(paneID, to: kind, in: store)
        }
        // Once geometry stops moving, every shell gets its authoritative size.
        store.onGeometrySettled = { [weak factory] in factory?.commitResize() }
        // A shell renames its own pane as it runs; the header follows.
        // A shell renames its own pane as it runs; the header follows, and so does the tab
        // when the pane doing the renaming is the focused one.
        factory.onDescriptorChange = { [weak store] paneID, record in
            store?.surfaces.updateRecord(record, for: paneID)
            if store?.tree.focused == paneID { store?.refreshWindowTitle() }
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
                perform(request, in: root, workspace: workspaceID)
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

    /// Everything one session owned, let go of.
    ///
    /// Called when a session is CLOSED, which is the only time this is right — switching away
    /// from one must leave its shells running, and that is the whole point of holding several.
    /// The order matters: history is captured while the panes still exist, and the panes are
    /// released before the factories that own them go.
    static func tearDown(_ store: LayoutStore) {
        let id = store.workspaceID
        Registry.factories[id]?.saveScrollback()
        store.persistNow()
        // Releasing every pane is what stops the PTYs — `PaneSurfaceStore.release` is the one
        // place a pane dies, and it calls back into both factories.
        store.surfaces.prune(keeping: [])
        Registry.channels[id]?.stop()
        Registry.channels[id] = nil
        Registry.factories[id] = nil
        Registry.tiles[id] = nil
        Registry.stores[id] = nil
        Registry.windows[id] = nil
        updateSleepGuard()
    }

    /// The live factory, so menu commands can reach the shells.
    enum Registry {
        @MainActor static var factories: [UUID: ShellPaneFactory] = [:]
        @MainActor static var tiles: [UUID: TileFactory] = [:]
        @MainActor static var stores: [UUID: LayoutStore] = [:]
        @MainActor static var channels: [UUID: AgentChannel] = [:]
        /// The window each workspace lives in, so an already-open project can be RAISED
        /// rather than opened twice. Two windows on one project both restore the same
        /// document id and both persist to it, so the second silently overwrites the
        /// first's layout — the same last-writer-wins collision as two editors on one file.
        @MainActor static var windows: [UUID: NSWindow] = [:]

        /// The workspace already open on this project, if any. Compared canonically, so a
        /// path spelled differently is still recognised as the same project.
        @MainActor static func store(forDirectory path: String) -> LayoutStore? {
            let wanted = WorkspaceDocument.canonical(path)
            return stores.values.first {
                $0.workspaceDirectory.map(WorkspaceDocument.canonical) == wanted
            }
        }

        /// The editor pane something should open in, within ONE workspace.
        ///
        /// The focused pane when it is itself an editor; otherwise the editor the user was
        /// last in, because clicking a row in the Git tile focuses the GIT tile and the
        /// answer has to survive that; otherwise the first editor in the layout. Nil when
        /// there is no editor at all, which is the caller's cue to make one.
        @MainActor static func editorTarget(in workspaceID: UUID) -> PaneID? {
            guard let store = stores[workspaceID], let tiles = tiles[workspaceID] else {
                return nil
            }
            let editors = tiles.editorPanes()
            let focused = store.tree.focused
            if editors.contains(focused) { return focused }
            // Validated, not trusted: the remembered pane may have been closed or converted
            // into something that is no longer an editor.
            if let last = store.lastFocusedEditor, editors.contains(last),
               store.tree.contains(last) {
                return last
            }
            return store.tree.paneIDs.first { editors.contains($0) }
        }

        /// Where a new tile should point: the working directory of the shell a tile would
        /// type into. Pane records carry the LIVE cwd — a shell reports its directory as it
        /// changes — so this follows `cd`.
        @MainActor static func workingDirectory(in workspaceID: UUID, fallback: URL) -> URL {
            guard let store = stores[workspaceID],
                  let target = injectionTarget(in: workspaceID),
                  let cwd = store.surfaces.records[target]?.cwd
            else { return fallback }
            return URL(fileURLWithPath: cwd)
        }

        /// The pane a tile's "send to shell" should type into, within ONE workspace.
        ///
        /// The focused pane when it is itself a shell; otherwise the shell the user was last
        /// working in, because pressing a control in a tile focuses that tile and the answer
        /// has to survive that; otherwise the first shell in the layout, for a workspace
        /// where no shell has been focused yet. Nil when there is no shell at all, in which
        /// case the verb is a no-op rather than a guess.
        @MainActor static func injectionTarget(in workspaceID: UUID) -> PaneID? {
            guard let store = stores[workspaceID], let factory = factories[workspaceID] else {
                return nil
            }
            let focused = store.tree.focused
            if factory.shells[focused] != nil { return focused }
            // Validated, not trusted: the remembered pane may have been closed or converted
            // into something that is no longer a shell.
            if let last = store.lastFocusedShell, factory.shells[last] != nil,
               store.tree.contains(last) {
                return last
            }
            return store.tree.paneIDs.first { factory.shells[$0] != nil }
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

    /// Show a file — or a file's diff — in an editor.
    ///
    /// Reuses an editor that is already open before it considers splitting a new pane, which
    /// is the whole difference between "clicking four changed files" being four tabs and
    /// being four panes on a canvas that has room for none of them. The same rule
    /// `injectIntoShell` follows: find the pane the user is working in, and use it.
    static func showInEditor(_ request: EditorRequest, in store: LayoutStore) {
        if let target = Registry.editorTarget(in: store.workspaceID),
           let session = Registry.tiles[store.workspaceID]?.editorSessions(for: target) {
            session.open(request)
            // Focused, because a tab that opens in a pane you are not looking at is a tab
            // you have to go and find. The click came from another pane, so nothing else
            // would move the focus there.
            store.focus(target)
            return
        }
        guard let edge = newPaneEdge(in: store) else { NSSound.beep(); return }
        Registry.tiles[store.workspaceID]?.stage(open: request)
        stageTile(.editor, for: store)
        if !store.split(edge: edge) {
            stageTile(nil, for: store)
            Registry.tiles[store.workspaceID]?.stage(open: nil)
        }
    }

    /// The tabs of the editor a keystroke should act on, or nil when there is no editor.
    ///
    /// Same target as `showInEditor`, so the menu acts on the pane the click would have
    /// filled. Nil rather than a guess: with no editor open there is no tab to switch to,
    /// and the menu items say so by being dimmed.
    static func editorSessions(in store: LayoutStore) -> EditorSessions? {
        guard let target = Registry.editorTarget(in: store.workspaceID) else { return nil }
        return Registry.tiles[store.workspaceID]?.editorSessions(for: target)
    }

    /// Open a new editor pane on a specific file. Kept for callers that mean a FILE.
    static func openEditor(on file: URL, in store: LayoutStore) {
        showInEditor(.file(file), in: store)
    }

    /// Open a new shell pane, optionally running an agent.
    static func openShell(agent: AgentDefinition? = nil, in store: LayoutStore) {
        guard let edge = newPaneEdge(in: store) else { NSSound.beep(); return }
        stageAgent(agent, for: store)
        if !store.split(edge: edge) { stageAgent(nil, for: store) }
    }

    /// Carry out one agent request, or say why not.
    @MainActor
    static func perform(_ request: AgentRequest, in root: URL,
                        workspace workspaceID: UUID) -> AgentResponse {
        let resolved: ResolvedAgentRequest
        do {
            resolved = try request.resolve(in: root)
        } catch let error as AgentRequestError {
            return .failure(error.message)
        } catch {
            return .failure("\(error)")
        }
        // This workspace's own window. The socket lives in the project, so a request that
        // arrived on it belongs to the project — not to whichever tab was opened first.
        guard let store = Registry.stores[workspaceID] else {
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
    /// A shell started or exited. The monitor polls anyway, but a lifecycle event is a
    /// known-good moment to look, so the badge and the assertion follow a launch or a quit
    /// immediately rather than up to one tick later.
    static func updateSleepGuard() {
        AgentMonitor.shared.sample()
    }

    // MARK: Folders

    /// Whether this pane is a tile that means something different in another folder — a
    /// file tree or a Git tile. False for shells, which change folder by `cd`, and for the
    /// tiles that are not scoped to a path at all.
    static func canSetFolder(_ paneID: PaneID, in store: LayoutStore) -> Bool {
        Registry.tiles[store.workspaceID]?.canRetarget(paneID) ?? false
    }

    /// Which folder a tile pane is currently showing.
    static func tileRoot(_ paneID: PaneID, in store: LayoutStore) -> URL? {
        Registry.tiles[store.workspaceID]?.root(of: paneID)
    }

    /// The project this workspace was opened on — where "Project Folder" sends a tile back to.
    static func projectFolder(of store: LayoutStore) -> URL {
        URL(fileURLWithPath: store.workspaceDirectory ?? NSHomeDirectory())
    }

    /// Point a tile pane at a different folder. The one verb behind the footer's folder
    /// menu, the file tree's `..` row, and the Pane ▸ Folder commands.
    static func setFolder(_ url: URL, of paneID: PaneID, in store: LayoutStore) {
        Registry.tiles[store.workspaceID]?.retarget(paneID, to: url)
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
