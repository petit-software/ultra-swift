import Testing
import AppKit
import CoreGraphics
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout

@Suite("Drop zones")
@MainActor
struct DropZoneTests {
    private let frame = CGRect(x: 100, y: 200, width: 400, height: 300)

    @Test("the middle of a pane swaps")
    func centre() {
        #expect(DropZone.at(CGPoint(x: frame.midX, y: frame.midY), in: frame) == .centre)
    }

    @Test("each edge band maps to its own edge")
    func edges() {
        #expect(DropZone.at(CGPoint(x: frame.minX + 10, y: frame.midY), in: frame) == .edge(.left))
        #expect(DropZone.at(CGPoint(x: frame.maxX - 10, y: frame.midY), in: frame) == .edge(.right))
        #expect(DropZone.at(CGPoint(x: frame.midX, y: frame.minY + 10), in: frame) == .edge(.top))
        #expect(DropZone.at(CGPoint(x: frame.midX, y: frame.maxY - 10), in: frame) == .edge(.bottom))
    }

    @Test("zones follow the pane's diagonals, the rule window snapping already taught")
    func diagonals() {
        let wide = CGRect(x: 0, y: 0, width: 1000, height: 200)
        // Above the descending diagonal -> top, regardless of how far from the left it is.
        #expect(DropZone.at(CGPoint(x: 200, y: 8), in: wide) == .edge(.top))
        #expect(DropZone.at(CGPoint(x: 200, y: 190), in: wide) == .edge(.bottom))
        // Left of it -> left, even though the pane is short.
        #expect(DropZone.at(CGPoint(x: 8, y: 100), in: wide) == .edge(.left))
        #expect(DropZone.at(CGPoint(x: 992, y: 100), in: wide) == .edge(.right))

        let tall = CGRect(x: 0, y: 0, width: 200, height: 1000)
        #expect(DropZone.at(CGPoint(x: 8, y: 200), in: tall) == .edge(.left))
        #expect(DropZone.at(CGPoint(x: 100, y: 8), in: tall) == .edge(.top))
    }

    @Test("the four edge zones and the centre tile the pane with no dead spots")
    func noDeadSpots() {
        var seen = Set<String>()
        for x in stride(from: 2.0, to: 400, by: 7) {
            for y in stride(from: 2.0, to: 300, by: 7) {
                let point = CGPoint(x: frame.minX + x, y: frame.minY + y)
                let zone = DropZone.at(point, in: frame)
                seen.insert(String(describing: zone))
                // Whatever it resolves to, the preview must lie inside the pane.
                #expect(frame.contains(zone.indicator(in: frame)))
            }
        }
        #expect(seen.count == 5, "every one of the five zones must be reachable")
    }

    @Test("the indicator previews where the pane actually lands")
    func indicators() {
        #expect(DropZone.centre.indicator(in: frame) == frame)
        #expect(DropZone.edge(.left).indicator(in: frame)
                == CGRect(x: 100, y: 200, width: 200, height: 300))
        #expect(DropZone.edge(.bottom).indicator(in: frame)
                == CGRect(x: 100, y: 350, width: 400, height: 150))
        // Every indicator stays inside the pane it previews.
        for zone in [DropZone.centre, .edge(.left), .edge(.right), .edge(.top), .edge(.bottom)] {
            #expect(frame.contains(zone.indicator(in: frame)))
        }
    }

    @Test("a degenerate frame does not produce NaNs")
    func degenerate() {
        #expect(DropZone.at(.zero, in: .zero) == .centre)
    }

    @Test("dropping a pane on itself is refused")
    func selfDropRefused() {
        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(.grid2x2)) { factory.makeContent(for: $0) }
        let canvas = SplitCanvasView(store: store)
        canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        canvas.layoutSubtreeIfNeeded()

        let pane = store.tree.paneIDs[0]
        let centre = canvas.currentResult.frames[pane]!
        #expect(canvas.dropPlan(at: CGPoint(x: centre.midX, y: centre.midY), dragging: pane) == nil)
    }

    @Test("dropping onto another pane resolves to that pane and a zone")
    func planResolves() {
        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(.grid2x2)) { factory.makeContent(for: $0) }
        let canvas = SplitCanvasView(store: store)
        canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        canvas.layoutSubtreeIfNeeded()

        let panes = store.tree.paneIDs
        let target = canvas.currentResult.frames[panes[3]]!
        let plan = try! #require(canvas.dropPlan(at: CGPoint(x: target.minX + 8, y: target.midY),
                                                 dragging: panes[0]))
        #expect(plan.target == panes[3])
        #expect(plan.zone == .edge(.left))
    }

    @Test("a centre drop swaps, an edge drop moves — and both keep the tree valid")
    func dropsApply() {
        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(.grid2x2)) { factory.makeContent(for: $0) }
        store.canvasBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let panes = store.tree.paneIDs

        store.swap(panes[0], panes[3])
        #expect(store.tree.paneIDs == [panes[3], panes[1], panes[2], panes[0]])
        #expect(store.tree.validate().isEmpty)

        store.move(panes[1], toEdgeOf: panes[0], edge: .bottom)
        #expect(store.tree.paneCount == 4)
        #expect(store.tree.validate().isEmpty)
        #expect(store.tree.focused == panes[1])
    }
}
