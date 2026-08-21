import Testing
import AppKit
import CoreGraphics
@testable import UltraCanvas
@testable import UltraLayout

/// The divider must be easy to grab and impossible to grab by accident. This is the path
/// verified by hand with synthetic mouse events; these lock it in so it stays verified.
@Suite("Divider hit-testing")
@MainActor
struct DividerHitTests {

    private func canvas(_ fixture: LayoutTree.Fixture,
                        size: CGSize = CGSize(width: 1200, height: 800)) -> SplitCanvasView {
        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(fixture)) { factory.makeContent(for: $0) }
        let view = SplitCanvasView(store: store)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test("the overlay takes the mouse over a divider and nowhere else")
    func overlayIsTransparentExceptOverDividers() {
        let view = canvas(.twoAcross)
        let divider = try! #require(view.currentResult.dividers.first)
        let overlayHit = view.hitTest(view.convert(CGPoint(x: divider.hitRect.midX,
                                                           y: divider.hitRect.midY),
                                                   to: view.superview))
        #expect(overlayHit is DividerOverlayView, "a click on the divider must reach the overlay")

        // The middle of a pane must fall through to the pane, never the overlay.
        let paneCentre = view.currentResult.frames.values.first!
        let paneHit = view.hitTest(view.convert(CGPoint(x: paneCentre.midX, y: paneCentre.midY),
                                                to: view.superview))
        #expect(!(paneHit is DividerOverlayView), "a click in a pane must not reach the overlay")
    }

    @Test("the hit area is more generous than the hairline the user aims at")
    func hitAreaExceedsLine() {
        let view = canvas(.grid2x2)
        #expect(!view.currentResult.dividers.isEmpty)
        for divider in view.currentResult.dividers {
            let hit = divider.axis == .horizontal ? divider.hitRect.width : divider.hitRect.height
            let line = divider.axis == .horizontal ? divider.lineRect.width : divider.lineRect.height
            #expect(hit >= 8, "hit area \(hit) is too small to aim at")
            #expect(hit > line * 4, "hit area should be far larger than the 1pt line")
            #expect(divider.hitRect.contains(CGPoint(x: divider.lineRect.midX,
                                                     y: divider.lineRect.midY)),
                    "the hairline must sit inside its own hit area")
        }
    }

    @Test("parallel dividers never compete for the same pixels")
    func parallelHitAreasAreDisjoint() {
        // Perpendicular dividers necessarily overlap where they cross; parallel ones
        // overlapping would mean two grabs for one gesture, which is a real bug.
        let view = canvas(.deepNest)
        let all = view.currentResult.dividers
        for i in all.indices {
            for j in all.indices where j > i && all[i].axis == all[j].axis {
                let overlap = all[i].hitRect.intersection(all[j].hitRect)
                #expect(overlap.isNull || overlap.width < 1 || overlap.height < 1,
                        "two parallel dividers compete: \(all[i].hitRect) / \(all[j].hitRect)")
            }
        }
    }

    @Test("a grab at a crossing resolves to the nearest hairline, deterministically")
    func crossingResolvesToNearest() {
        let view = canvas(.deepNest)
        let all = view.currentResult.dividers
        var crossings = 0

        for a in all {
            for b in all where b.axis != a.axis {
                let overlap = a.hitRect.intersection(b.hitRect)
                guard !overlap.isNull, overlap.width >= 1, overlap.height >= 1 else { continue }
                crossings += 1

                // Aim clearly at a's line, inside both hit areas: a must win.
                let aimed = CGPoint(x: a.axis == .horizontal ? a.lineRect.midX : overlap.midX,
                                    y: a.axis == .horizontal ? overlap.midY : a.lineRect.midY)
                guard a.hitRect.contains(aimed), b.hitRect.contains(aimed) else { continue }
                let picked = try! #require(view.currentResult.divider(at: aimed))
                #expect(picked.ref == a.ref,
                        "aiming at \(a.axis) divider resolved to \(picked.axis)")

                // And the answer must not depend on evaluation order.
                #expect(view.currentResult.divider(at: aimed)?.ref == picked.ref)
            }
        }
        #expect(crossings > 0, "the deep-nest fixture should contain divider crossings")
    }

    @Test("every divider resolves back to a real container in the tree")
    func dividersResolve() {
        let view = canvas(.deepNest)
        for divider in view.currentResult.dividers {
            let path = view.store.tree.root.path(toNode: divider.ref.containerID)
            let container = try! #require(path.flatMap { view.store.tree.root[$0].asContainer })
            #expect(container.fractions.indices.contains(divider.ref.index + 1))
            #expect(divider.containerSize > 0)
        }
    }

    @Test("panes clear the titlebar while the canvas itself stays full-bleed")
    func layoutBoundsClearsTitlebar() {
        let view = canvas(.single)
        view.window?.styleMask.insert(.fullSizeContentView)
        view.layoutSubtreeIfNeeded()
        #expect(view.layoutBounds.height <= view.bounds.height)
        #expect(view.layoutBounds.width == view.bounds.width)
    }
}
