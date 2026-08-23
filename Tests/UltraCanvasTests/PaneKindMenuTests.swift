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

    private func srgb(_ colour: Color) -> NSColor {
        NSColor(colour).usingColorSpace(.sRGB)!
    }
    private func spread(_ colour: Color) -> CGFloat {
        let c = srgb(colour)
        return max(c.redComponent, c.greenComponent, c.blueComponent)
             - min(c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// Both inputs are passed in rather than read from the tokens. `paneBackground` and
    /// `accent` are live settings another target's suite mutates while this one runs, and
    /// reading ground, accent, and border as three separate statements let the accent change
    /// between two of them — the border then got checked against arithmetic done on a colour
    /// it was never derived from. That failed roughly one run in ten and read as a broken
    /// ratio rather than as a race, which is what makes it worth a comment this long.
    @Test("the border sits the tuning fraction of the way from the pane to the accent")
    func borderIsAMixTowardTheAccent() {
        let ground = Color(nsColor: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1))
        let accent = Color(nsColor: NSColor(srgbRed: 0.90, green: 0.31, blue: 0.20, alpha: 1))
        let border = srgb(Token.Colour.focusBorder(mixing: ground, toward: accent))
        let ratio = CGFloat(Token.Colour.focusBorderOpacity)

        func mixed(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * ratio }
        let g = srgb(ground), a = srgb(accent)
        #expect(abs(border.redComponent - mixed(g.redComponent, a.redComponent)) < 0.02)
        #expect(abs(border.greenComponent - mixed(g.greenComponent, a.greenComponent)) < 0.02)
        #expect(abs(border.blueComponent - mixed(g.blueComponent, a.blueComponent)) < 0.02)
    }

    /// The fraction the user asked for, asserted as a NUMBER rather than as a ratio.
    /// Everything else here holds for any weight, so nothing else would notice this
    /// silently drifting back to a rounder value.
    @Test("the ring carries 0.64 of the tint")
    func ringWeightIsWhatWasAskedFor() {
        #expect(abs(Token.Colour.focusBorderOpacity - 0.64) < 0.0001)
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

    /// Passes a KNOWN tint in rather than reading `Token.Colour.accent`, which defaults to
    /// White — a legitimate setting for which "the ring carries a hue" is false and should
    /// be. Phrased as a `#require` on the ambient accent this failed whenever another suite
    /// left the accent neutral.
    @Test("a tinted accent reaches the ring — it does not come out neutral")
    func ringCarriesTheAccentHue() {
        let ground = Color(nsColor: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        let tint = Color(nsColor: NSColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1))
        #expect(spread(Token.Colour.focusBorder(mixing: ground, toward: tint)) > spread(ground),
                "the ring came out neutral — the accent never reached it")
    }

    /// A neutral accent must NOT invent a hue. The mix is the only thing standing between
    /// "White" as a setting and a ring that quietly tints anyway.
    @Test("a white accent leaves the ring neutral")
    func neutralAccentStaysNeutral() {
        let ground = Color(nsColor: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        #expect(spread(Token.Colour.focusBorder(mixing: ground, toward: .white)) < 0.02)
    }
}
