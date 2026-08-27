import Testing
import AppKit
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraDesign
@testable import UltraLayout

/// A theme that reaches the terminal text and nothing else is a theme that does not work.
///
/// Every one of these covers a pane that was left behind: the background opacity was painted
/// only under shells, so a window of a shell and three tiles answered the slider on one pane
/// out of four, and the theme itself was written into the store once at construction and
/// never again, so changing it in Settings moved nothing already on screen.
@Suite("A theme reaches every pane")
@MainActor
struct PaneThemeTests {

    private func store(_ fixture: LayoutTree.Fixture = .grid2x2,
                       theme: TerminalTheme = .dark) -> LayoutStore {
        let store = LayoutStore(tree: .fixture(fixture), theme: theme) { _ in
            PaneContent(view: NSView(),
                        record: PaneRecord(kind: .placeholder, title: "Pane"))
        }
        // A split is refused on a canvas with no size, and these need real panes.
        store.canvasBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        // Materialise them: a surface is built lazily, and a theme has to reach the ones
        // that already exist as well as the ones that do not yet.
        for paneID in store.tree.paneIDs { _ = store.surfaces.surface(for: paneID) }
        return store
    }

    private func backdropAlpha(_ container: PaneContainerView) -> CGFloat {
        container.layoutSubtreeIfNeeded()
        guard let colour = container.backdropColourForTesting else { return -1 }
        return colour.alpha
    }

    @Test("every pane wears the opacity, not just the shells")
    func opacityReachesEveryPane() {
        let store = store(.grid2x2)
        var theme = TerminalTheme.dark
        theme.backgroundOpacity = 0.6
        store.theme = theme

        let panes = store.tree.paneIDs.compactMap { store.surfaces.existingSurface(for: $0) }
        #expect(panes.count == 4, "the fixture needs four real panes")
        for pane in panes {
            #expect(abs(backdropAlpha(pane) - 0.6) < 0.01)
        }
    }

    @Test("a pane opened after a theme change opens in the new theme")
    func newPaneAdoptsTheCurrentTheme() {
        let store = store(.single)
        var theme = TerminalTheme.light
        theme.backgroundOpacity = 0.4
        store.theme = theme

        #expect(store.split(edge: .right), "the test needs a second pane")
        let fresh = try! #require(store.tree.paneIDs.last.map { store.surfaces.surface(for: $0) })
        #expect(abs(backdropAlpha(fresh) - 0.4) < 0.01,
                "a pane built after the change must not open in the theme the window launched with")
    }

    @Test("switching theme repaints panes that already exist")
    func themeSwitchRepaintsLivePanes() {
        let store = store(.twoAcross, theme: .dark)
        var dark = TerminalTheme.dark
        dark.backgroundOpacity = 1
        store.theme = dark
        let pane = try! #require(store.tree.paneIDs.first.flatMap {
            store.surfaces.existingSurface(for: $0)
        })
        let before = try! #require(pane.backdropColourForTesting)

        var light = TerminalTheme.light
        light.backgroundOpacity = 1
        store.theme = light
        let after = try! #require(pane.backdropColourForTesting)

        #expect(before != after, "the surface must follow the theme, not the launch")
        let brightness = { (colour: CGColor) -> CGFloat in
            NSColor(cgColor: colour)?.usingColorSpace(.sRGB)?.brightnessComponent ?? -1
        }
        #expect(brightness(before) < 0.2)
        #expect(brightness(after) > 0.8)
    }

    @Test("at zero the pane paints nothing and the glass is the surface")
    func zeroOpacityLeavesTheGlassAlone() {
        let store = store(.twoAcross)
        var theme = TerminalTheme.dark
        theme.backgroundOpacity = 0
        store.theme = theme

        for paneID in store.tree.paneIDs {
            let pane = try! #require(store.surfaces.existingSurface(for: paneID))
            #expect(backdropAlpha(pane) < 0.01)
        }
    }
}
