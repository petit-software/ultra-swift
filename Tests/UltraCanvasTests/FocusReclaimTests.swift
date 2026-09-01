import AppKit
import Testing
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout

/// Model focus drives AppKit focus, never the other way round. The hole that leaves is
/// everything that takes first responder WITHOUT changing the model — a sidebar click, a
/// toolbar menu, a dismissed popover — after which the caret sits outside the canvas with
/// nothing to bring it back. That is a terminal you cannot type into.
@Suite("Reclaiming the keyboard")
@MainActor
struct FocusReclaimTests {

    private func makeStore() -> (LayoutStore, [PaneID]) {
        let tree = LayoutTree.fixture(.threeAcross)
        let ids = tree.paneIDs
        let store = LayoutStore(tree: tree) { _ in
            PaneContent(view: NSView(), record: PaneRecord(kind: .shell, title: "pane"))
        }
        for id in ids { _ = store.surfaces.surface(for: id) }
        return (store, ids)
    }

    @Test("asking for the keyboard back is observable")
    func reclaimBumpsTheRevision() {
        let (store, _) = makeStore()
        let before = store.focusRevision
        store.reclaimKeyboardFocus()
        #expect(store.focusRevision == before + 1)
    }

    /// The one keyboard route back from a lost first responder. ⌘1 on the pane you are
    /// already in used to be a no-op, so the escape hatch did nothing precisely when it was
    /// needed.
    @Test("focusing the already-focused pane asks for the keyboard back")
    func refocusingSamePaneReclaims() {
        let (store, ids) = makeStore()
        let before = store.focusRevision
        store.focus(ids[0])
        #expect(store.tree.focused == ids[0])
        #expect(store.focusRevision == before + 1,
                "⌘1 while already on pane 1 has to be a way back to the terminal")
    }

    /// A real focus move already re-asserts through the model change itself, so it must not
    /// also spend a revision — that would make every focus change fire the deferred
    /// re-assert as well.
    @Test("moving focus normally does not need a reclaim")
    func realMoveDoesNotReclaim() {
        let (store, ids) = makeStore()
        let before = store.focusRevision
        store.focus(ids[1])
        #expect(store.tree.focused == ids[1])
        #expect(store.focusRevision == before)
    }

    @Test("focusing a pane that is not in the tree does nothing at all")
    func unknownPaneIsIgnored() {
        let (store, ids) = makeStore()
        let before = store.focusRevision
        store.focus(PaneID())
        #expect(store.tree.focused == ids[0])
        #expect(store.focusRevision == before)
    }

    /// The canvas acts once per request. `updateNSView` runs constantly, and a view that
    /// grabbed the keyboard on every one of them would make the sidebar unclickable.
    @Test("a repeated revision is acted on once")
    func revisionIsActedOnOnce() {
        let (store, _) = makeStore()
        let view = SplitCanvasView(store: store)
        store.reclaimKeyboardFocus()
        let revision = store.focusRevision

        view.reclaimKeyboardFocus(revision: revision)
        #expect(view.pendingFocusRevisionForTesting == revision)
        view.noteFocusAttempt(landed: true)
        #expect(view.lastFocusRevisionForTesting == revision)
        #expect(view.pendingFocusRevisionForTesting == nil)

        // Same revision again — SwiftUI re-running `updateNSView` for an unrelated change.
        view.reclaimKeyboardFocus(revision: revision)
        #expect(view.pendingFocusRevisionForTesting == nil,
                "a request already satisfied must not queue a second grab")

        store.reclaimKeyboardFocus()
        view.reclaimKeyboardFocus(revision: store.focusRevision)
        view.noteFocusAttempt(landed: true)
        #expect(view.lastFocusRevisionForTesting == store.focusRevision)
    }

    /// The session-switch bug, as a rule.
    ///
    /// SwiftUI calls `updateNSView` on a brand-new representable BEFORE putting its view in
    /// the window, so the reclaim that comes with a switched-to canvas fires with nothing to
    /// focus. Spending the revision on that attempt left the request looking satisfied and
    /// nothing ever tried again — on launch the window's `didBecomeKey` hid it, but a switch
    /// inside a window that is already key has no second chance, and the shell could not be
    /// typed into.
    @Test("a reclaim that could not land is kept, not spent")
    func failedAttemptIsRetried() {
        let (store, _) = makeStore()
        let view = SplitCanvasView(store: store)
        store.reclaimKeyboardFocus()
        let revision = store.focusRevision

        view.reclaimKeyboardFocus(revision: revision)
        // The canvas is not in a window yet — exactly the state SwiftUI hands it in.
        view.noteFocusAttempt(landed: false)

        #expect(view.pendingFocusRevisionForTesting == revision,
                "a switch that lost the race must still be owed the keyboard")
        #expect(view.lastFocusRevisionForTesting != revision,
                "an attempt that did nothing must not count as the request being met")

        // The next chance — `viewDidMoveToWindow`, or the window becoming key.
        view.noteFocusAttempt(landed: true)
        #expect(view.lastFocusRevisionForTesting == revision)
        #expect(view.pendingFocusRevisionForTesting == nil)
    }

    /// Landing without a request outstanding must not rewrite the revision — otherwise an
    /// ordinary focus assert would swallow the NEXT reclaim's guard.
    @Test("focusing with nothing pending changes no bookkeeping")
    func landingWithoutRequestIsInert() {
        let (store, _) = makeStore()
        let view = SplitCanvasView(store: store)
        let before = view.lastFocusRevisionForTesting
        view.noteFocusAttempt(landed: true)
        #expect(view.lastFocusRevisionForTesting == before)
        #expect(view.pendingFocusRevisionForTesting == nil)
    }
}
