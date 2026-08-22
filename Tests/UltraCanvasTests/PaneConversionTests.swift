import Testing
import AppKit
import CoreGraphics
@testable import UltraCanvas
@testable import UltraLayout

/// Switching a pane's kind must change only its CONTENTS. If it changed the tree, the pane
/// would jump position or lose its size — and a conversion the user has to re-arrange after
/// is worse than opening a new pane.
@Suite("Pane conversion")
@MainActor
struct PaneConversionTests {

    private func makeCanvas() -> (SplitCanvasView, LayoutStore, PlaceholderPaneFactory) {
        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(.threeAcross)) { factory.makeContent(for: $0) }
        let view = SplitCanvasView(store: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        view.layoutSubtreeIfNeeded()
        return (view, store, factory)
    }

    @Test("conversion keeps the pane's identity, position and size")
    func preservesGeometry() {
        let (view, store, _) = makeCanvas()
        let target = store.tree.paneIDs[1]
        let treeBefore = store.tree
        let frameBefore = view.currentResult.frames[target]

        store.replaceContent(of: target)
        view.sync()
        view.layoutSubtreeIfNeeded()

        #expect(store.tree == treeBefore, "the tree must not change")
        #expect(store.tree.paneIDs.contains(target), "the pane keeps its id")
        #expect(view.currentResult.frames[target] == frameBefore, "and its rectangle")
    }

    @Test("the old surface is torn down, and a fresh one is built")
    func rebuildsSurface() {
        let (view, store, _) = makeCanvas()
        let target = store.tree.paneIDs[0]
        let before = store.surfaces.surface(for: target)
        view.sync()

        store.replaceContent(of: target)
        view.sync()
        view.layoutSubtreeIfNeeded()

        let after = store.surfaces.surface(for: target)
        #expect(before !== after, "a new surface, not the old one re-used")
        #expect(before.superview == nil, "the old surface left the view tree")
        #expect(after.superview === view)
    }

    @Test("releasing a pane runs the teardown that stops its process")
    func releaseIsAnnounced() {
        let (_, store, _) = makeCanvas()
        var released: [PaneID] = []
        store.surfaces.onRelease = { released.append($0) }
        let target = store.tree.paneIDs[2]
        _ = store.surfaces.surface(for: target)

        store.replaceContent(of: target)
        #expect(released == [target],
                "conversion must tear the old content down — a shell's PTY depends on it")
    }

    @Test("the revision changes, so the canvas knows to rebuild")
    func revisionAdvances() {
        let (_, store, _) = makeCanvas()
        let before = store.surfaceRevision
        store.replaceContent(of: store.tree.paneIDs[0])
        #expect(store.surfaceRevision > before)
    }

    @Test("converting every pane in turn leaves the layout intact")
    func repeatedConversion() {
        let (view, store, _) = makeCanvas()
        let treeBefore = store.tree
        let framesBefore = view.currentResult.frames
        for paneID in store.tree.paneIDs {
            store.replaceContent(of: paneID)
            view.sync()
            view.layoutSubtreeIfNeeded()
        }
        #expect(store.tree == treeBefore)
        #expect(view.currentResult.frames == framesBefore)
    }
}

/// "New pane" must not be a command that can only beep. Splitting the longer axis is what
/// keeps room available; when nothing fits, callers need to know before offering the verb.
@Suite("New pane placement")
@MainActor
struct NewPanePlacementTests {

    private func store(_ fixture: LayoutTree.Fixture, size: CGSize) -> LayoutStore {
        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(fixture)) { factory.makeContent(for: $0) }
        store.canvasBounds = CGRect(origin: .zero, size: size)
        return store
    }

    @Test("a wide pane splits sideways, a tall one splits downwards")
    func splitsTheLongerAxis() {
        let wide = store(.single, size: CGSize(width: 1200, height: 400))
        #expect(firstViableEdge(in: wide) == .right)

        let tall = store(.single, size: CGSize(width: 400, height: 1200))
        #expect(firstViableEdge(in: tall) == .bottom)
    }

    @Test("a canvas with no room reports none rather than offering a doomed split")
    func noRoom() {
        let cramped = store(.single, size: CGSize(width: 180, height: 90))
        #expect(firstViableEdge(in: cramped) == nil)
    }

    /// Mirrors ShellWorkspace.newPaneEdge, which lives in the app target and cannot be
    /// imported here — the RULE is what matters and it is asserted against the same
    /// `canSplit` the app calls.
    private func firstViableEdge(in store: LayoutStore) -> Edge? {
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
}
