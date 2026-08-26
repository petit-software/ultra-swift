import Testing
import AppKit
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout

/// A tile's "send to shell" has to know which shell the user is working in, and
/// `tree.focused` cannot tell it: pressing a control in a tile focuses the TILE, so by the
/// time the send runs the focused pane is the one doing the sending. Without the memory
/// below, every send fell back to the first shell in the layout — which is why text typed
/// from the Context tile always landed in the same pane, whichever one the user was using.
@Suite("Last focused shell")
@MainActor
struct ShellFocusTests {

    /// Three panes across: shell, tile, shell. Surfaces are materialised because a pane
    /// with no surface has no record, and a record is how a shell is recognised.
    private func makeStore(kinds: [PaneRecord.Kind]) -> (LayoutStore, [PaneID]) {
        let tree = LayoutTree.fixture(.threeAcross)
        let ids = tree.paneIDs
        let byID = Dictionary(uniqueKeysWithValues: zip(ids, kinds))
        let store = LayoutStore(tree: tree) { paneID in
            PaneContent(view: NSView(),
                        record: PaneRecord(kind: byID[paneID] ?? .placeholder,
                                           title: "pane",
                                           cwd: "/tmp/\(byID[paneID]?.rawValue ?? "x")"))
        }
        for id in ids { _ = store.surfaces.surface(for: id) }
        return (store, ids)
    }

    @Test("focusing a tile does not lose the shell that was being worked in")
    func tileFocusKeepsTheShell() {
        let (store, ids) = makeStore(kinds: [.shell, .git, .shell])
        store.focus(ids[2])
        store.focus(ids[1])          // the user presses a control in the Git tile

        #expect(store.tree.focused == ids[1])
        #expect(store.lastFocusedShell == ids[2],
                "the send belongs to the shell the user was in, not the first in the layout")
    }

    /// A restored window opens focused on a shell without anyone clicking it. If only
    /// ARRIVING at a pane counted, that shell would never be recorded, and the first send
    /// of the session would go to the wrong pane.
    @Test("the shell a restored window opens on counts, even unclicked")
    func focusOnRestoreCounts() {
        let (store, ids) = makeStore(kinds: [.shell, .git, .shell])
        #expect(store.tree.focused == ids[0], "the fixture opens on the first pane")
        #expect(store.lastFocusedShell == nil)

        store.focus(ids[1])
        #expect(store.lastFocusedShell == ids[0], "leaving a shell records it")
    }

    @Test("a workspace with no shell has nothing to remember")
    func noShells() {
        let (store, ids) = makeStore(kinds: [.git, .fileTree, .todo])
        store.focus(ids[1])
        store.focus(ids[2])
        #expect(store.lastFocusedShell == nil, "better nothing than a guess")
    }

    @Test("the memory follows the most recent shell, not the first one")
    func mostRecentWins() {
        let (store, ids) = makeStore(kinds: [.shell, .shell, .git])
        store.focus(ids[1])
        #expect(store.lastFocusedShell == ids[1])
        store.focus(ids[0])
        #expect(store.lastFocusedShell == ids[0])
        store.focus(ids[2])
        #expect(store.lastFocusedShell == ids[0], "the tile in between changes nothing")
    }
}
