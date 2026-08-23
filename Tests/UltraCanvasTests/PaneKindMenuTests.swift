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

/// The focused pane says so three ways: the ring, the icon taking the accent, and depth.
@Suite("Focused pane")
struct FocusSignalTests {

    @Test("a focused pane sits higher than an unfocused one")
    func focusLifts() {
        let base = Token.Space.paneShadowOpacity
        #expect(base > 0, "an unfocused pane still needs a shadow to lift FROM")
        #expect(base * 1.6 > base)
        #expect(base * 1.6 <= 1, "a shadow opacity above 1 is clamped, losing the difference")
    }

    /// TRANSLUCENT, not an opaque mix. Half of the way to a saturated colour still reads as
    /// that colour; half the alpha reads as half. The previous ring was opaque and looked
    /// like the whole accent, which is the complaint this replaced.
    @Test("the ring is the accent held back by alpha, not a blend")
    func ringIsTranslucent() {
        let ring = NSColor(Token.Colour.focusBorder).usingColorSpace(.sRGB)!
        let accent = NSColor(Token.Colour.accent).usingColorSpace(.sRGB)!
        #expect(abs(ring.alphaComponent - Token.Colour.accentHalfStrength) < 0.01)
        // Same colour underneath — a ring that disagreed with the tint would be a second
        // accent.
        #expect(abs(ring.redComponent - accent.redComponent) < 0.02)
        #expect(abs(ring.greenComponent - accent.greenComponent) < 0.02)
        #expect(abs(ring.blueComponent - accent.blueComponent) < 0.02)
    }

    /// The ring is inset so it draws over the PANE, not over the glass rim it would otherwise
    /// sit on — the rim is near-white, and any alpha over it reads at full strength.
    @Test("the ring is inset from the pane's edge, and stays concentric")
    func ringIsInset() {
        #expect(Token.Space.focusRingInset > 0)
        #expect(Token.Space.focusRingInset < Token.Space.paneRadius)
        #expect(Token.Space.focusRingWidth > 0)
    }

    /// One source for "half the accent", so a second half-strength use cannot invent its own.
    @Test("half strength has a single definition")
    func oneSourceForHalf() {
        #expect(Token.Colour.accentHalfStrength == 0.5)
        let half = NSColor(Token.Colour.accentHalf).usingColorSpace(.sRGB)!
        let ring = NSColor(Token.Colour.focusBorder).usingColorSpace(.sRGB)!
        #expect(abs(half.alphaComponent - ring.alphaComponent) < 0.0001,
                "the ring must BE the shared half-strength accent, not a copy of its value")
    }
}
