import AppKit
import Observation
import UltraCore
import UltraDesign
import UltraLayout

/// The observable owner of one canvas: its tree, its pane surfaces, and its undo history.
///
/// Every user-facing verb lives here, so the menu, the command palette, and the keymap
/// all drive the same code. See the `keyboard-first` skill.
@MainActor
@Observable
public final class LayoutStore {
    public private(set) var tree: LayoutTree
    public var metrics: LayoutMetrics
    /// Chrome follows the terminal theme, so the window reads as ONE surface rather than
    /// light chrome bolted to a dark terminal. See docs/02-DESIGN-LANGUAGE.md.
    ///
    /// Writing it is what a theme change IS: the window's pinned appearance reads it, and
    /// the pane surfaces are pushed from it here, so no caller has to remember to do both.
    public var theme: TerminalTheme {
        didSet {
            guard theme != oldValue else { return }
            surfaces.apply(theme: theme)
            // A pane moved to a window of its own is still this session's, and wears its look.
            for window in paneWindows { window.theme = theme }
        }
    }
    /// What this window is. Shown in the window bar.
    /// The PROJECT's name. Persisted, and what a workspace is called in recents.
    public var workspaceTitle: String = "Ultra" {
        didSet { refreshWindowTitle() }
    }

    /// What the window and its TAB are called.
    ///
    /// Deliberately not the same thing as `workspaceTitle`. The project name is what a
    /// workspace IS and belongs in the document; the tab label is where you currently are,
    /// which is the question a row of tabs has to answer. They were one value, so every tab
    /// on a project read identically and none of them moved when a shell changed directory.
    ///
    /// Follows the FOCUSED pane, because that is the one being worked in — the same rule
    /// Terminal and iTerm use.
    public private(set) var windowTitle: String = "Ultra"
    public var workspaceSubtitle: String?
    /// The project this workspace is open on. Written into the document so the layout can be
    /// found again BY PATH the next time this project is opened.
    public var workspaceDirectory: String?
    /// Last laid-out canvas bounds, so commands can reason about geometry.
    public internal(set) var canvasBounds: CGRect = .zero

    /// Bumped when a pane's CONTENT is replaced while the tree stays the same.
    ///
    /// The canvas rebuilds surfaces only for panes it does not already have, which is what
    /// keeps a split from touching its siblings. Converting a pane changes nothing about the
    /// tree, so without this the canvas would correctly conclude there is nothing to do.
    public private(set) var surfaceRevision = 0

    /// Replace what a pane holds, keeping its id, its position and its size.
    ///
    /// The old surface is released — which is what stops a converted shell's PTY — and the
    /// next layout pass builds the replacement through the same factory chain as a new pane.
    public func replaceContent(of paneID: PaneID) {
        surfaces.release(paneID)
        surfaceRevision += 1
    }

    @ObservationIgnored public let surfaces: PaneSurfaceStore
    /// How a pane's content is built. Kept so a canvas in a pane window builds through
    /// exactly the factories this one does.
    @ObservationIgnored private let makeSurface: (PaneID) -> PaneContent

    /// The session this canvas is a pane window of; nil for the session's own canvas. See
    /// "Pane windows" below.
    @ObservationIgnored public private(set) weak var owner: LayoutStore?
    /// The canvases this session has in windows of their own, held by the session's own
    /// store so they live and die with the session.
    @ObservationIgnored public private(set) var paneWindows: [LayoutStore] = []
    /// A pane window has been made: the app opens a window for it.
    @ObservationIgnored public var onPaneWindowCreated: ((LayoutStore) -> Void)?
    /// This pane window is finished with — its panes went back, or its session closed —
    /// and its window should close.
    @ObservationIgnored public var onDismiss: (() -> Void)?
    @ObservationIgnored public let undoManager = UndoManager()
    @ObservationIgnored private var navigation = NavigationMemory()
    @ObservationIgnored private var nextPaneNumber = 0

    /// Where this workspace lives on disk. Nil means an unsaved scratch canvas.
    @ObservationIgnored public var storage: WorkspaceStorage?
    @ObservationIgnored public let workspaceID: UUID
    /// Last known window frame, so a window reopens where it was.
    @ObservationIgnored public var windowFrame: CGRect?

    /// The shell pane the user was last working in.
    ///
    /// `tree.focused` cannot answer this on its own: pressing a control in a TILE focuses
    /// that tile, so by the time a tile's "send to shell" runs, the focused pane is the tile
    /// doing the sending. Falling back to "the first shell in the layout" from there meant
    /// every send landed in the same pane forever, whichever one the user was actually
    /// typing in.
    ///
    /// Nil until a shell has been focused at least once, and never validated here — a pane
    /// can close, so the reader checks that it still exists.
    @ObservationIgnored public private(set) var lastFocusedShell: PaneID?

    /// The editor pane the user was last working in.
    ///
    /// Exactly the same problem `lastFocusedShell` solves, for exactly the same reason:
    /// clicking a row in the Git tile focuses the GIT tile, so by the time "show this diff"
    /// runs, the focused pane is the one doing the asking. Without this, every diff would
    /// land in the first editor in the layout for the rest of the session.
    @ObservationIgnored public private(set) var lastFocusedEditor: PaneID?

    /// Called when the tree changes, after persistence has been scheduled.
    @ObservationIgnored public var onChange: ((LayoutTree) -> Void)?
    /// Called once geometry has stopped moving — a divider drag committed, a window resize
    /// ended. From M2 this is where a PTY gets its authoritative size.
    @ObservationIgnored public var onGeometrySettled: (() -> Void)?

    public init(tree: LayoutTree,
                metrics: LayoutMetrics = .default,
                theme: TerminalTheme = .dark,
                workspaceID: UUID = UUID(),
                storage: WorkspaceStorage? = nil,
                makeSurface: @escaping (PaneID) -> PaneContent) {
        self.workspaceID = workspaceID
        self.storage = storage
        self.tree = tree
        self.metrics = metrics
        self.theme = theme
        self.makeSurface = makeSurface
        self.surfaces = PaneSurfaceStore(make: makeSurface)
        // `didSet` does not run during init, and a pane built before the first theme change
        // would otherwise wear the store's default rather than this window's.
        self.surfaces.apply(theme: theme)
        // A pane window restored from a document has no records until its canvas first lays
        // its panes out; its name is only known then.
        surfaces.onBuild = { [weak self] paneID in
            guard let self, tree.focused == paneID else { return }
            refreshWindowTitle()
        }
        // Header controls call exactly the same verbs as the menu and the palette.
        surfaces.actions.split = { [weak self] paneID, edge in self?.split(edge: edge, paneID: paneID) }
        surfaces.actions.close = { [weak self] paneID in self?.close(paneID) }
        surfaces.actions.focus = { [weak self] paneID in self?.focus(paneID) }
        surfaces.actions.windowMove = { [weak self] paneID in self?.windowMove(for: paneID) }
    }

    /// Teach the pane headers what a pane can become. The canvas has no idea what a "Todo"
    /// is; it lays out rectangles, so the list and the verb both come from the app.
    public func setPaneKinds(_ kinds: @escaping () -> [PaneKindChoice],
                             change: @escaping (PaneID, PaneRecord.Kind) -> Void) {
        surfaces.actions.kinds = kinds
        surfaces.actions.changeKind = change
    }

    public var layoutResult: LayoutResult {
        layout(tree, in: canvasBounds, metrics: metrics)
    }

    // MARK: - Mutation

    /// Apply a change, register undo for it, and notify.
    /// Opt-in tracing for diagnosing layout loss. `ULTRA_TRACE=1 swift run Ultra`.
    static let isTracing = ProcessInfo.processInfo.environment["ULTRA_TRACE"] == "1"

    func trace(_ message: @autoclosure () -> String) {
        guard Self.isTracing else { return }
        FileHandle.standardError.write(Data("[ultra] \(message())\n".utf8))
    }

    public func apply(_ name: String, _ change: (inout LayoutTree) -> Bool) {
        let previous = tree
        var candidate = tree
        guard change(&candidate), candidate != previous else { return }
        trace("apply \(name): \(previous.paneCount) -> \(candidate.paneCount) panes")
        tree = candidate
        registerUndo(from: previous, name: name)
        surfaces.prune(keeping: Set(candidate.paneIDs))
        persist()
        onGeometrySettled?()
        onChange?(candidate)
    }

    /// An undo entry whose undoing is a verb rather than a tree: moving a pane between
    /// windows cannot be undone by restoring a tree, because the pane's view went with it.
    /// `undo` registers its own opposite, so redo works the same way back.
    private func registerUndo(_ name: String, _ undo: @escaping (LayoutStore) -> Void) {
        undoManager.setActionName(name)
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { undo(store) }
        }
    }

    private func registerUndo(from previous: LayoutTree, name: String) {
        undoManager.setActionName(name)
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                let redoFrom = store.tree
                store.tree = previous
                store.registerUndo(from: redoFrom, name: name)
                store.onChange?(previous)
            }
        }
    }

    /// Replace the whole canvas with another arrangement — every pane released, every
    /// surface rebuilt through the factories from whatever records they now hold.
    ///
    /// The one verb behind "apply this layout to all projects". Not routed through `apply`:
    /// that registers an undo, and undoing this would restore a tree whose panes no longer
    /// have processes, records or history behind them — a canvas of fresh shells wearing
    /// old ids. So the undo stack is emptied instead, and the confirmation this is reached
    /// through says so.
    public func adopt(tree newTree: LayoutTree) {
        guard newTree.validate().isEmpty else { return }
        trace("adopt: \(tree.paneCount) -> \(newTree.paneCount) panes")
        surfaces.prune(keeping: [])
        tree = newTree
        undoManager.removeAllActions()
        navigation = NavigationMemory()
        lastFocusedShell = nil
        lastFocusedEditor = nil
        refreshWindowTitle()
        persist()
        onGeometrySettled?()
        onChange?(newTree)
    }

    // MARK: - Commands

    @discardableResult
    public func split(edge: Edge, paneID: PaneID? = nil) -> Bool {
        let source = paneID ?? tree.focused
        guard canSplit(tree, pane: source, edge: edge, in: canvasBounds, metrics: metrics) else {
            NSSound.beep()
            return false
        }
        let newPane = PaneID()
        apply("Split \(edge.actionName)") { $0.split(source, edge: edge, newPane: newPane) }
        return true
    }

    public func closeFocused() { close(tree.focused) }

    public func close(_ paneID: PaneID) {
        guard tree.paneCount > 1 else { NSSound.beep(); return }
        navigation.forget(paneID)
        // Panes vanishing without the user asking is the worst failure this app can have,
        // so closes record where they came from. `ULTRA_TRACE=1 swift run Ultra`.
        trace("CLOSE \(paneID.uuidString.prefix(8)) from "
              + Thread.callStackSymbols.dropFirst(2).prefix(4)
                .map { $0.split(separator: " ").dropFirst(3).prefix(3).joined(separator: " ") }
                .joined(separator: " <- "))
        apply("Close Pane") { $0.close(paneID) }
    }

    /// Ask the canvas to put the caret back in the focused pane.
    ///
    /// The model is the only source of truth for "what does a keystroke act on", and the
    /// canvas re-asserts AppKit's first responder from it whenever the model changes. The
    /// hole that leaves is everything that takes first responder WITHOUT changing the model:
    /// clicking a sidebar row, opening a toolbar menu, dismissing a popover. Focus then sits
    /// outside the canvas with nothing to bring it back, which is a terminal you cannot type
    /// into.
    ///
    /// A counter rather than a call, because the canvas is an `NSView` the store must not
    /// hold: this is observed, so bumping it drives `updateNSView` exactly like a tree
    /// change does.
    public private(set) var focusRevision = 0

    public func reclaimKeyboardFocus() { focusRevision &+= 1 }

    /// The one place focus changes. Every other focus entry point funnels through here, so
    /// there is no way to move focus without it being persisted — that gap is why a
    /// restored window came back focused on the wrong pane.
    public func focus(_ paneID: PaneID) {
        guard tree.contains(paneID) else { return }
        // Focusing the pane that is ALREADY focused is not a no-op: it is what ⌘1 does when
        // the caret has been left in the sidebar, and answering "you are already there" is
        // how the one keyboard route back from a lost first responder does nothing.
        guard paneID != tree.focused else {
            reclaimKeyboardFocus()
            return
        }
        // The pane being LEFT counts too. A restored window opens focused on a shell without
        // anyone clicking it, so the first thing that ever moves focus — pressing a control
        // in a tile — is also the only chance to record which shell was being worked in.
        noteShellFocus(tree.focused)
        tree.focused = paneID   // not a structural change: no undo entry
        noteShellFocus(paneID)
        refreshWindowTitle()
        persist()
    }

    /// Remember a focused SHELL, so a tile knows where to type. A pane with no surface yet
    /// has no record to read, which is why this is a no-op rather than a guess.
    private func noteShellFocus(_ paneID: PaneID) {
        switch surfaces.records[paneID]?.kind {
        case .shell, .agent: lastFocusedShell = paneID
        case .editor: lastFocusedEditor = paneID
        default: break
        }
    }

    /// Re-read the window title from the focused pane.
    ///
    /// Called on focus changes and whenever a pane reports a new directory. The surface
    /// store is not `@Observable`, so a record changing cannot drive this on its own — the
    /// value has to be pushed onto the store that IS observed, or the tab label silently
    /// stops following the shell.
    public func refreshWindowTitle() {
        let name = isPaneWindow ? paneName : surfaces.records[tree.focused]?.cwd
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
        // A pane with no directory of its own — a tile — leaves the project name showing
        // rather than blanking the tab.
        let title = name ?? workspaceTitle
        // Called from every layout pass that builds a pane, and an observed property set to
        // the value it already holds still invalidates every view that reads it.
        if windowTitle != title { windowTitle = title }
    }

    /// A pane window is named for what its focused pane is SHOWING — the header's own title:
    /// the file an editor has open, the page a browser is on, the agent or folder a shell
    /// is in. A shell's title is a path, and a path is named by its last folder, the way
    /// the main window's tab is.
    private var paneName: String? {
        guard let title = surfaces.records[tree.focused]?.title, !title.isEmpty else { return nil }
        guard title.hasPrefix("/") || title.hasPrefix("~") else { return title }
        let last = URL(fileURLWithPath: title).lastPathComponent
        return last.isEmpty || last == "~" ? title : last
    }

    public func moveFocus(_ direction: Edge) {
        let frames = layoutResult.frames
        guard let target = focusTarget(from: tree.focused, direction: direction,
                                       frames: frames, memory: navigation) else {
            NSSound.beep()
            return
        }
        navigation.record(from: tree.focused, to: target, edge: direction)
        focus(target)
    }

    public func focusPane(atVisualIndex index: Int) {
        let order = layoutResult.visualOrder
        guard order.indices.contains(index) else { NSSound.beep(); return }
        focus(order[index])
    }

    /// ⌃⌘→ grows the focused pane rightwards by moving the divider on its right edge.
    /// `points` is always positive-means-grow; the sign flip depends on which side of the
    /// divider the pane sits on.
    public func resizeFocused(_ edge: Edge, by points: CGFloat) {
        guard let divider = tree.nearestDivider(to: tree.focused, edge: edge, in: layoutResult) else {
            NSSound.beep()
            return
        }
        let delta = (edge == .right || edge == .bottom) ? points : -points
        let minimum = metrics.minPaneSize.size(along: divider.axis)
        apply("Resize Panes") {
            $0.resize(divider: divider.ref, by: delta,
                      containerSize: divider.containerSize, minPaneSize: minimum) != 0
        }
    }

    /// Committed once per drag, so a drag is a single undo entry.
    public func commitDrag(_ dragged: LayoutTree) {
        apply("Resize Panes") { current in
            guard current != dragged else { return false }
            current = dragged
            return true
        }
        onGeometrySettled?()
    }

    public func toggleZoom() {
        let pane = tree.focused
        apply("Zoom Pane") { $0.toggleZoom(pane); return true }
    }

    public func equalizeFocusedContainer() {
        guard let path = tree.root.path(toPane: tree.focused), !path.isEmpty else { return }
        let containerID = tree.root[Array(path.dropLast())].id
        apply("Equalize Panes") { $0.equalize(container: containerID) }
    }

    public func equalizeAll() {
        apply("Equalize All Panes") { $0.equalizeAll(); return true }
    }

    /// Every row of side-by-side panes shared out evenly — three columns a third each —
    /// with the heights of stacked panes left as they are. See `LayoutTree.equalize(axis:)`.
    public func equalizeColumns() {
        apply("Equalize Column Widths") { $0.equalize(axis: .horizontal) }
    }

    /// The other way round: every stack of panes shared out evenly — two in a column half
    /// each, three a third — with the widths of side-by-side panes left as they are.
    public func equalizeRows() {
        apply("Equalize Row Heights") { $0.equalize(axis: .vertical) }
    }

    public func move(_ paneID: PaneID, toEdgeOf target: PaneID, edge: Edge) {
        apply("Move Pane") { $0.move(paneID, toEdgeOf: target, edge: edge) }
    }

    public func swap(_ a: PaneID, _ b: PaneID) {
        apply("Swap Panes") { $0.swap(a, b) }
    }

    /// Move a pane to one edge of the whole canvas, spanning that side.
    public func move(_ paneID: PaneID, toRootEdge edge: Edge) {
        apply("Move Pane to Edge") { $0.move(paneID, toRootEdge: edge) }
    }

    /// Perform whatever a drop resolved to. One entry point, so the drag handler does not
    /// have to know which of three operations a zone corresponds to.
    public func apply(_ target: DropTarget) {
        switch target {
        case .swap(let other): swap(tree.focused, other)
        case .edge(let other, let edge): move(tree.focused, toEdgeOf: other, edge: edge)
        case .root(let edge): move(tree.focused, toRootEdge: edge)
        }
    }

    /// The same, for a drag that names its own pane rather than using the focused one.
    public func apply(_ target: DropTarget, dragging paneID: PaneID) {
        switch target {
        case .swap(let other): swap(paneID, other)
        case .edge(let other, let edge): move(paneID, toEdgeOf: other, edge: edge)
        case .root(let edge): move(paneID, toRootEdge: edge)
        }
    }
}

// MARK: - Persistence

extension LayoutStore {
    /// The workspace exactly as it should come back.
    public var document: WorkspaceDocument {
        var document = WorkspaceDocument(id: workspaceID,
                                         directory: workspaceDirectory,
                                         title: workspaceTitle,
                                         subtitle: workspaceSubtitle,
                                         tree: tree,
                                         panes: [:],
                                         windowFrame: windowFrame,
                                         themeID: theme.id,
                                         paneWindows: paneWindows.map {
                                             PaneWindowLayout(tree: $0.tree, frame: $0.windowFrame)
                                         })
        // Ensure every pane in the tree has a record, even one never yet materialised.
        for paneID in tree.paneIDs {
            document.setRecord(surfaces.records[paneID] ?? surfaces.surfaceRecord(for: paneID),
                               for: paneID)
        }
        for window in paneWindows {
            for paneID in window.tree.paneIDs {
                document.setRecord(window.surfaces.records[paneID]
                                       ?? window.surfaces.surfaceRecord(for: paneID),
                                   for: paneID)
            }
        }
        return document
    }

    /// Debounced write. Structural changes and focus changes both persist; divider drags
    /// persist once, on commit, because that is where the model is written.
    public func persist(_ reason: String = #function) {
        // A pane window has no document of its own: it is a part of its session's.
        if let owner { owner.persist(reason); return }
        guard let storage else { return }
        let document = document
        trace("persist \(document.tree.paneCount) panes (from \(reason))")
        storage.scheduleSave(document)
    }

    /// Write immediately. Called on termination, where a debounce would lose the last edit.
    public func persistNow() {
        if let owner { owner.persistNow(); return }
        guard let storage else { return }
        storage.flush()
        try? storage.saveNow(document)
    }

    public func noteWindowFrame(_ frame: CGRect) {
        guard windowFrame != frame else { return }
        windowFrame = frame
        persist()
        onGeometrySettled?()
    }
}

extension Edge {
    /// Menu- and undo-friendly name: "Undo Split Right" reads better than "Undo Split".
    public var actionName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Up"
        case .bottom: "Down"
        }
    }
}

// MARK: - Pane windows

/// A pane moved out of its window into one of its own.
///
/// It stays in its SESSION. The window holds a canvas of its own — a `LayoutStore` with the
/// same workspace id, building through the same factories, persisting into the same
/// document — so the pane keeps its shell, its project, its agent socket and every
/// Registry lookup that goes by workspace. What moves is the view: the live surface is
/// handed from one `PaneSurfaceStore` to the other (`handOver`), never released and never
/// rebuilt, which is the one rule this app does not bend — a pane's process outlives every
/// layout change, and a window is a layout change.
///
/// Only the session's own canvas sends panes out, and it holds every pane window it made.
/// Closing a pane window brings its panes back rather than stopping them; closing the
/// SESSION stops them with the rest.
extension LayoutStore {
    public var isPaneWindow: Bool { owner != nil }

    /// What macOS calls this canvas's window — in the Dock's menu, the Window menu and
    /// Mission Control. The main window is the app's, so it is "Ultra"; a pane window is
    /// its pane's, so it takes the name the pane's header shows (`windowTitle`), which is
    /// how two windows of one app are told apart in a list of them.
    public var systemWindowTitle: String { isPaneWindow ? windowTitle : "Ultra" }

    /// The session's own store, whichever canvas this is.
    public var session: LayoutStore { owner ?? self }

    /// The canvas that has this pane — the session's or one of its pane windows'.
    public func holder(of paneID: PaneID) -> LayoutStore? {
        let session = session
        return ([session] + session.paneWindows).first {
            $0.tree.contains(paneID) || $0.surfaces.existingSurface(for: paneID) != nil
        }
    }

    /// Whether this pane can go to a window of its own: it is on the session's canvas, and
    /// it is not the last pane there — a canvas with nothing on it is a window with
    /// nothing in it.
    public func canMoveToNewWindow(_ paneID: PaneID? = nil) -> Bool {
        let paneID = paneID ?? tree.focused
        return !isPaneWindow && tree.contains(paneID) && tree.paneCount > 1
    }

    /// Move a pane into a new window of its own. Undoable: ⌘Z in the main window brings
    /// it back to where it was, while it is still in that window.
    @discardableResult
    public func moveToNewWindow(_ paneID: PaneID? = nil) -> LayoutStore? {
        let paneID = paneID ?? tree.focused
        guard canMoveToNewWindow(paneID) else { NSSound.beep(); return nil }
        let previous = tree
        trace("MOVE TO WINDOW \(paneID.uuidString.prefix(8))")
        guard let window = sendToNewWindow([paneID]) else { return nil }
        registerUndo("Move Pane to New Window") { store in
            guard let window = store.paneWindows.first(where: { $0.tree.contains(paneID) })
            else { return }
            store.takeBack([paneID], from: window, restoring: previous)
        }
        return window
    }

    /// Bring a pane in a pane window back to the session's canvas, beside the pane that
    /// has focus there. The window closes when it has nothing left.
    public func moveBackToMainWindow(_ paneID: PaneID? = nil) {
        let paneID = paneID ?? tree.focused
        guard let owner, tree.contains(paneID) else { NSSound.beep(); return }
        owner.takeBack([paneID], from: self)
    }

    /// Every pane of a pane window back to the session's canvas: what closing the window
    /// does. Nothing stops.
    public func returnAllPanes() {
        owner?.takeBack(tree.paneIDs, from: self)
    }

    /// The pane's window entry for its header menu: out to a window of its own, or back.
    /// Back wears the arrows pointing IN, the same glyph as the pane window's own control
    /// and the menu item, so the three read as one verb.
    func windowMove(for paneID: PaneID) -> (title: String, symbol: String, run: () -> Void)? {
        if isPaneWindow {
            return ("Move Pane Back to Main Window", "arrow.up.right.and.arrow.down.left", { [weak self] in
                self?.moveBackToMainWindow(paneID)
            })
        }
        guard canMoveToNewWindow(paneID) else { return nil }
        return ("Move Pane to New Window", "macwindow", { [weak self] in self?.moveToNewWindow(paneID) })
    }

    /// Pane windows from a saved document, before any of their panes is built: the panes
    /// come up through the factories when each window's canvas first lays them out. A
    /// layout naming a pane the main canvas already has is skipped — one pane, one place.
    public func restorePaneWindows(_ layouts: [PaneWindowLayout]) {
        var placed = Set(tree.paneIDs)
        for layout in layouts where placed.isDisjoint(with: layout.tree.paneIDs) {
            placed.formUnion(layout.tree.paneIDs)
            onPaneWindowCreated?(makePaneWindow(tree: layout.tree, frame: layout.frame?.rect))
        }
    }

    /// The session is closing: every pane in its pane windows stops with it, and the
    /// windows close.
    public func closePaneWindows() {
        for window in paneWindows {
            window.surfaces.prune(keeping: [])
            dissolve(window)
        }
    }

    // MARK: Moving panes between canvases

    /// A pane window of this session, on `tree`. Not announced: the caller does that once
    /// the panes are in it, or a canvas laid out at once would build them a second time.
    private func makePaneWindow(tree: LayoutTree, frame: CGRect?) -> LayoutStore {
        let window = LayoutStore(tree: tree, metrics: metrics, theme: theme,
                                 workspaceID: workspaceID, storage: nil,
                                 makeSurface: makeSurface)
        window.owner = self
        window.windowFrame = frame
        window.workspaceTitle = workspaceTitle
        window.workspaceSubtitle = workspaceSubtitle
        window.workspaceDirectory = workspaceDirectory
        // The same process teardown and the same settled-size commit as the session's own
        // panes: a pane closed in a pane window stops its shell like any other.
        window.surfaces.onRelease = surfaces.onRelease
        window.onGeometrySettled = onGeometrySettled
        window.surfaces.actions.kinds = surfaces.actions.kinds
        paneWindows.append(window)
        return window
    }

    /// Panes of this canvas into one new pane window, side by side. No undo entry: the
    /// callers register their own.
    private func sendToNewWindow(_ panes: [PaneID]) -> LayoutStore? {
        let moving = panes.filter(tree.contains)
        guard let first = moving.first, moving.count < tree.paneCount else { return nil }
        var windowTree = LayoutTree(single: first)
        var candidate = tree
        for paneID in moving {
            // Built now if it never has been, so there is a live surface to hand over
            // rather than a pane the new window would build a second time.
            _ = surfaces.surface(for: paneID)
            if paneID != first { windowTree.split(windowTree.focused, edge: .right, newPane: paneID) }
            candidate.close(paneID)
        }
        let window = makePaneWindow(tree: windowTree, frame: nil)
        for paneID in moving { surfaces.handOver(paneID, to: window.surfaces) }
        // Named once its pane's record has come across with it.
        window.refreshWindowTitle()
        commitWithoutUndo(candidate)
        onPaneWindowCreated?(window)
        return window
    }

    /// Take panes from a pane window into this canvas.
    ///
    /// Into `restoring` when given — the tree as it was before the pane left, which is how
    /// an undo puts it back exactly — and otherwise each beside the focused pane.
    fileprivate func takeBack(_ panes: [PaneID], from window: LayoutStore,
                              restoring: LayoutTree? = nil) {
        guard window.owner === self else { return }
        let moving = panes.filter(window.tree.contains)
        guard !moving.isEmpty else { return }
        var candidate = restoring ?? tree
        for paneID in moving {
            // A pane the window never built has no surface to hand over; this canvas
            // builds it when it lays it out, as a restore would.
            window.surfaces.handOver(paneID, to: surfaces)
            if restoring == nil { candidate.split(candidate.focused, edge: .right, newPane: paneID) }
        }
        if let last = moving.last { candidate.focused = last }
        let remaining = window.tree.paneIDs.filter { !moving.contains($0) }
        if remaining.isEmpty {
            dissolve(window)
        } else {
            var shrunk = window.tree
            for paneID in moving { shrunk.close(paneID) }
            // The window's own history names the panes that just left it, and undoing
            // into one of them would build a second shell on the same id.
            window.undoManager.removeAllActions()
            window.commitWithoutUndo(shrunk)
        }
        commitWithoutUndo(candidate)
        if restoring == nil {
            registerUndo("Move Pane Back to Main Window") { store in
                guard let window = store.sendToNewWindow(moving) else { return }
                store.registerUndo("Move Pane Back to Main Window") { store in
                    store.takeBack(moving, from: window)
                }
            }
        } else {
            registerUndo("Move Pane to New Window") { store in
                guard let window = store.sendToNewWindow(moving) else { return }
                store.registerUndo("Move Pane to New Window") { store in
                    store.takeBack(moving, from: window, restoring: restoring)
                }
            }
        }
        reclaimKeyboardFocus()
    }

    /// Forget a pane window and close it. Its panes have gone elsewhere, or the caller
    /// has released them.
    private func dissolve(_ window: LayoutStore) {
        paneWindows.removeAll { $0 === window }
        window.owner = nil
        window.onDismiss?()
    }

    /// Replace the tree without an undo entry: for a move whose undo is a verb.
    private func commitWithoutUndo(_ candidate: LayoutTree) {
        guard candidate != tree else { return }
        tree = candidate
        surfaces.prune(keeping: Set(candidate.paneIDs))
        refreshWindowTitle()
        persist()
        onGeometrySettled?()
        onChange?(candidate)
    }
}
