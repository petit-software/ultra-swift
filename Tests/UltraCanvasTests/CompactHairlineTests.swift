import Testing
import AppKit
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraDesign
@testable import UltraLayout

/// The compact grid's hairline leaves off the side of a cell that lies along the
/// window's top or bottom edge: the window's edge is the line there.
@Suite("Compact grid hairlines")
@MainActor
struct CompactHairlineTests {

    private func canvas(bottomInset: CGFloat = 0) -> (SplitCanvasView, LayoutStore) {
        let store = LayoutStore(tree: .fixture(.grid2x2), theme: .dark) { _ in
            PaneContent(view: NSView(), record: PaneRecord(kind: .placeholder, title: "Pane"))
        }
        // As the app's windows have it: the settings' metrics, and the canvas running to
        // the window's top but for the compact grid's 2pt.
        store.metrics = .fromSettings
        let view = SplitCanvasView(store: store)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.topInset = Appearance.compact ? 2 : 8
        view.bottomInset = bottomInset
        view.layoutSubtreeIfNeeded()
        return (view, store)
    }

    /// Whether the pane's hairline has a line along its top, and one along its bottom.
    private func horizontals(of pane: PaneContainerView) -> (top: Bool, bottom: Bool) {
        var top = false, bottom = false, from = CGPoint.zero
        pane.hairlinePathForTesting?.applyWithBlock { element in
            let to = element.pointee.points[0]
            if element.pointee.type == .addLineToPoint, to.y == from.y {
                if to.y < 1 { top = true }
                if to.y > pane.bounds.height - 1 { bottom = true }
            }
            from = to
        }
        return (top, bottom)
    }

    private func compact(_ body: () -> Void) {
        let name = "ultra.tests.compactHairline.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite) {
            Appearance.gridMode = .compact
            body()
        }
    }

    @Test("a cell on the window's top edge has no top line, one on its bottom edge no bottom line")
    func edgesAlongTheWindowAreOpen() { compact {
        let (view, store) = canvas()
        let panes = store.tree.paneIDs.compactMap { store.surfaces.existingSurface(for: $0) }
        #expect(panes.count == 4)
        for pane in panes {
            let isTop = pane.frame.minY < 3, isBottom = pane.frame.maxY > view.bounds.maxY - 1
            #expect(isTop != isBottom)
            #expect(pane.openEdges == (isTop ? .top : .bottom))
            pane.layoutSubtreeIfNeeded()
            let lines = horizontals(of: pane)
            #expect(lines.top == !isTop)
            #expect(lines.bottom == !isBottom)
        }
    } }

    @Test("with the session belt under the panes, the bottom row keeps its bottom line")
    func aBeltKeepsTheBottomLine() { compact {
        let (_, store) = canvas(bottomInset: 40)
        let panes = store.tree.paneIDs.compactMap { store.surfaces.existingSurface(for: $0) }
        #expect(panes.allSatisfy { !$0.openEdges.contains(.bottom) })
    } }

    @Test("the relaxed grid draws no hairline at all")
    func relaxedHasNone() {
        let (_, store) = canvas()
        let panes = store.tree.paneIDs.compactMap { store.surfaces.existingSurface(for: $0) }
        #expect(panes.allSatisfy { $0.hairlinePathForTesting == nil })
    }
}
