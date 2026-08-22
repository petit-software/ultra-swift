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

@Suite("Selected pane border")
struct FocusBorderTests {

    /// Deliberately reads the CURRENT accent rather than setting one. `Preferences` is
    /// global, another target's suite mutates it concurrently, and swapping its store from
    /// two places is a flake this project has already paid for twice. The property here is
    /// a ratio, which holds whatever the accent happens to be.
    @Test("the border sits the tuning fraction of the way from the pane to the accent")
    func borderIsAMixTowardTheAccent() {
        let ground = NSColor(Token.Colour.paneBackground).usingColorSpace(.sRGB)!
        let accent = NSColor(Token.Colour.accent).usingColorSpace(.sRGB)!
        let border = NSColor(Token.Colour.focusBorder).usingColorSpace(.sRGB)!
        let ratio = CGFloat(Token.Colour.focusBorderOpacity)

        func mixed(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * ratio }
        #expect(abs(border.redComponent - mixed(ground.redComponent, accent.redComponent)) < 0.02)
        #expect(abs(border.greenComponent - mixed(ground.greenComponent, accent.greenComponent)) < 0.02)
        #expect(abs(border.blueComponent - mixed(ground.blueComponent, accent.blueComponent)) < 0.02)
    }

    /// The regression this guards is real and was shipped: a TRANSLUCENT ring drew on the
    /// clip layer inside the pane's glass, so it composited over the glass rim — a near-white
    /// edge — rather than over the pane. The fraction then meant nothing, because what it was
    /// a fraction OF depended on the material behind it.
    @Test("the ring is opaque, so nothing behind it can dilute the fraction")
    @MainActor
    func ringIsOpaque() {
        #expect(Token.Colour.focusBorder.nsColor.cgColor.alpha > 0.99)
    }

    @Test("the ring is a tint, not a neutral — it must carry the accent's hue")
    func ringCarriesTheAccentHue() {
        let ground = NSColor(Token.Colour.paneBackground).usingColorSpace(.sRGB)!
        let accent = NSColor(Token.Colour.accent).usingColorSpace(.sRGB)!
        let border = NSColor(Token.Colour.focusBorder).usingColorSpace(.sRGB)!
        // Only meaningful when the accent is itself a tint; "White" is a legitimate setting.
        let accentSpread = max(accent.redComponent, accent.greenComponent, accent.blueComponent)
            - min(accent.redComponent, accent.greenComponent, accent.blueComponent)
        try? #require(accentSpread > 0.05)
        guard accentSpread > 0.05 else { return }
        let borderSpread = max(border.redComponent, border.greenComponent, border.blueComponent)
            - min(border.redComponent, border.greenComponent, border.blueComponent)
        let groundSpread = max(ground.redComponent, ground.greenComponent, ground.blueComponent)
            - min(ground.redComponent, ground.greenComponent, ground.blueComponent)
        #expect(borderSpread > groundSpread, "the ring came out neutral — the accent never reached it")
    }
}
