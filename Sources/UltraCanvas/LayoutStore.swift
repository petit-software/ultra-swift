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
    public var theme: TerminalTheme
    /// What this window is. Shown in the window bar.
    public var workspaceTitle: String = "Ultra"
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
    @ObservationIgnored public let undoManager = UndoManager()
    @ObservationIgnored private var navigation = NavigationMemory()
    @ObservationIgnored private var nextPaneNumber = 0

    /// Where this workspace lives on disk. Nil means an unsaved scratch canvas.
    @ObservationIgnored public var storage: WorkspaceStorage?
    @ObservationIgnored public let workspaceID: UUID
    /// Last known window frame, so a window reopens where it was.
    @ObservationIgnored public var windowFrame: CGRect?

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
        self.surfaces = PaneSurfaceStore(make: makeSurface)
        // Header controls call exactly the same verbs as the menu and the palette.
        surfaces.actions.split = { [weak self] paneID, edge in self?.split(edge: edge, paneID: paneID) }
        surfaces.actions.close = { [weak self] paneID in self?.close(paneID) }
        surfaces.actions.focus = { [weak self] paneID in self?.focus(paneID) }
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

    /// The one place focus changes. Every other focus entry point funnels through here, so
    /// there is no way to move focus without it being persisted — that gap is why a
    /// restored window came back focused on the wrong pane.
    public func focus(_ paneID: PaneID) {
        guard tree.contains(paneID), paneID != tree.focused else { return }
        tree.focused = paneID   // not a structural change: no undo entry
        persist()
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

    public func move(_ paneID: PaneID, toEdgeOf target: PaneID, edge: Edge) {
        apply("Move Pane") { $0.move(paneID, toEdgeOf: target, edge: edge) }
    }

    public func swap(_ a: PaneID, _ b: PaneID) {
        apply("Swap Panes") { $0.swap(a, b) }
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
                                         themeID: theme.id)
        // Ensure every pane in the tree has a record, even one never yet materialised.
        for paneID in tree.paneIDs {
            document.setRecord(surfaces.records[paneID] ?? surfaces.surfaceRecord(for: paneID),
                               for: paneID)
        }
        return document
    }

    /// Debounced write. Structural changes and focus changes both persist; divider drags
    /// persist once, on commit, because that is where the model is written.
    public func persist(_ reason: String = #function) {
        guard let storage else { return }
        let document = document
        trace("persist \(document.tree.paneCount) panes (from \(reason))")
        storage.scheduleSave(document)
    }

    /// Write immediately. Called on termination, where a debounce would lose the last edit.
    public func persistNow() {
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
