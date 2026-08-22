import Testing
import AppKit
import CoreGraphics
@testable import UltraCanvas
@testable import UltraDesign
@testable import UltraLayout

/// Appearance values live in layer state — corner radii, shadows, blur filters — which is set
/// once when a view is built. A settings change therefore has to be pushed to those layers;
/// only the layout pass re-reads on its own. These lock that push in, because the failure
/// mode is silent: the slider moves, the number changes, and the window does not.
@Suite("Appearance re-apply", .serialized)
@MainActor
struct AppearanceReapplyTests {

    private func canvas() -> (SplitCanvasView, LayoutStore) {
        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(.twoAcross)) { factory.makeContent(for: $0) }
        let view = SplitCanvasView(store: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        view.layoutSubtreeIfNeeded()
        return (view, store)
    }

    @Test("a pane's corner radius follows the setting")
    func paneRadiusReachesLayers() {
        Appearance.reset()
        defer { Appearance.reset() }
        let (view, store) = canvas()
        let pane = store.tree.paneIDs[0]

        Appearance.set(.paneRadius, 4)
        view.appearanceChanged()
        view.layoutSubtreeIfNeeded()

        let surface = store.surfaces.surface(for: pane)
        #expect(Token.Space.paneRadius == 4)
        // The clip layer is what actually rounds the pane; assert on it directly rather
        // than on whichever subview happens to be first.
        #expect(surface.appliedCornerRadius == 4,
                "the setting changed but the pane's layer kept the old radius")
    }

    @Test("a value outside the knob's range is clamped, not applied")
    func outOfRangeIsClamped() {
        Appearance.reset()
        defer { Appearance.reset() }
        let (view, store) = canvas()
        Appearance.set(.gutter, 999)
        view.appearanceChanged()
        #expect(store.metrics.gutter == Appearance.knob(.gutter).range.upperBound)
    }

    @Test("the gutter reaches the layout metrics, not just the token")
    func gutterReachesMetrics() {
        Appearance.reset()
        defer { Appearance.reset() }
        let (view, store) = canvas()
        let before = store.layoutResult.frames[store.tree.paneIDs[0]]!.width

        Appearance.set(.gutter, 28)   // inside the knob's 0...32 range
        view.appearanceChanged()
        view.layoutSubtreeIfNeeded()

        // The store is the single source of truth: `canSplit` and keyboard resize read it
        // too, so a gutter that only reached the layout pass would leave those disagreeing.
        #expect(store.metrics.gutter == 28)
        let after = store.layoutResult.frames[store.tree.paneIDs[0]]!.width
        #expect(after < before, "a wider gutter must take width from the panes")
    }

    @Test("window padding reaches the metrics too")
    func paddingReachesMetrics() {
        Appearance.reset()
        defer { Appearance.reset() }
        let (view, store) = canvas()

        Appearance.set(.canvasPadding, 30)
        view.appearanceChanged()
        view.layoutSubtreeIfNeeded()
        #expect(store.metrics.padding == 30)
    }

    @Test("a store built while a setting is customised starts with it applied")
    func newStoreStartsCustomised() {
        Appearance.reset()
        defer { Appearance.reset() }
        Appearance.set(.gutter, 26)

        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(.twoAcross)) { factory.makeContent(for: $0) }
        // Otherwise a new window opens on the defaults and jumps when anything nudges it.
        #expect(store.metrics.gutter == 26)
    }
}
