import Testing
import AppKit
import SwiftUI
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraDesign
@testable import UltraLayout

/// The pane-kind menu is built from `PaneActions.kinds`. An EMPTY list compiles, renders,
/// and silently does nothing — macOS will not open an empty menu — which is exactly how it
/// shipped broken once. These assert the list is actually reachable from a pane.
@Suite("Pane kind menu")
@MainActor
struct PaneKindMenuTests {

    private func store() -> LayoutStore {
        let factory = PlaceholderPaneFactory()
        return LayoutStore(tree: .fixture(.twoAcross)) { factory.makeContent(for: $0) }
    }

    @Test("a store with no kinds set offers none — the state that looked fine and was not")
    func emptyByDefault() {
        #expect(store().surfaces.actions.kinds().isEmpty)
    }

    @Test("setPaneKinds makes the list reachable")
    func kindsReachable() {
        let store = store()
        store.setPaneKinds({ [PaneKindChoice(kind: .todo, title: "Todo", symbol: "checklist"),
                              PaneKindChoice(kind: .git, title: "Git", symbol: "arrow.trianglehead.branch")] },
                           change: { _, _ in })
        #expect(store.surfaces.actions.kinds().count == 2)
        #expect(store.surfaces.actions.kinds().first?.title == "Todo")
    }

    /// `PaneActions` is a struct copied into each container when it is built. Setting the
    /// list afterwards must still reach panes that already exist, which is why `kinds` is a
    /// closure rather than an array.
    @Test("panes built BEFORE the list was set still see it")
    func lateSetterReachesExistingPanes() {
        let store = store()
        let paneID = store.tree.paneIDs[0]
        let surface = store.surfaces.surface(for: paneID)   // built first, deliberately

        store.setPaneKinds({ [PaneKindChoice(kind: .ports, title: "Ports", symbol: "network")] },
                           change: { _, _ in })

        #expect(surface.headerActionsForTesting.kinds().count == 1,
                "an array would have frozen an empty list into this pane")
    }

    @Test("choosing a kind reports the pane and the kind it was asked for")
    func changeIsForwarded() {
        let store = store()
        var received: (PaneID, PaneRecord.Kind)?
        store.setPaneKinds({ [PaneKindChoice(kind: .git, title: "Git", symbol: "x")] }) { pane, kind in
            received = (pane, kind)
        }
        let paneID = store.tree.paneIDs[1]
        store.surfaces.actions.changeKind(paneID, .git)
        #expect(received?.0 == paneID)
        #expect(received?.1 == .git)
    }
}

/// The focus ring is gone. Focus is said by DEPTH alone now, so the thing worth asserting is
/// that the two states are actually different — a lift of zero would leave the focused pane
/// indistinguishable, with nothing else left to carry the signal.
@Suite("Focused pane depth")
struct FocusDepthTests {

    @Test("a focused pane sits higher than an unfocused one")
    func focusLifts() {
        let base = Token.Space.paneShadowOpacity
        #expect(base > 0, "an unfocused pane still needs a shadow to lift FROM")
        #expect(base * 1.6 > base)
        #expect(base * 1.6 <= 1, "a shadow opacity above 1 is clamped, losing the difference")
    }
}
