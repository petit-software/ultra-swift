import Testing
import CoreGraphics
@testable import UltraLayout

/// Hit-testing for pane drag-and-drop, as pure geometry.
///
/// A 1000×600 canvas holding two panes side by side, which is enough to catch every rule:
/// the root band, the swap centre, and the diagonals.
@Suite("Drop zones")
struct DropZoneTests {

    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let a = LayoutTree.fixturePane(1)
    private let b = LayoutTree.fixturePane(2)

    private var frames: [PaneID: CGRect] {
        [a: CGRect(x: 0, y: 0, width: 500, height: 600),
         b: CGRect(x: 500, y: 0, width: 500, height: 600)]
    }

    private func target(_ x: CGFloat, _ y: CGFloat, dragging: PaneID? = nil) -> DropTarget? {
        DropZone.target(at: CGPoint(x: x, y: y), frames: frames, canvas: canvas,
                        dragged: dragging ?? LayoutTree.fixturePane(9))
    }

    // MARK: The root band — the case the five per-pane zones cannot express

    @Test("the outer margin splits the ROOT, not the pane under it")
    func marginHitsRoot() {
        #expect(target(4, 300) == .root(.left))
        #expect(target(996, 300) == .root(.right))
        #expect(target(500, 4) == .root(.top))
        #expect(target(500, 596) == .root(.bottom))
    }

    /// The band reaches INSIDE the outermost pane. Confined to the gutter it would be a
    /// target a few points wide, which is not one anybody can hit while dragging an image.
    @Test("the band reaches inside the pane, not just the gutter")
    func bandReachesInside() {
        #expect(target(20, 300) == .root(.left), "20pt in is still the window's left side")
        #expect(target(60, 300) != .root(.left), "60pt in belongs to the pane")
    }

    /// A drag released past the window's content still means "that side". Refusing it makes
    /// the gesture fail exactly where people aim.
    @Test("outside the canvas still counts as its nearest side")
    func outsideStillCounts() {
        #expect(target(-30, 300) == .root(.left))
        #expect(target(1030, 300) == .root(.right))
    }

    /// Two bands meet on the corner's diagonal rather than one winning by declaration order.
    @Test("a corner belongs to the band it is deeper into")
    func cornersUseDepth() {
        #expect(target(6, 20) == .root(.left), "closer to the left edge than the top")
        #expect(target(20, 6) == .root(.top), "closer to the top edge than the left")
    }

    /// Splitting the root around the only pane there is would be a no-op wearing a gesture.
    @Test("with a single pane there is nothing to split the root around")
    func singlePaneRefusesRoot() {
        let only = [a: canvas]
        #expect(DropZone.target(at: CGPoint(x: 4, y: 300), frames: only,
                                canvas: canvas, dragged: b) == nil)
    }

    // MARK: The per-pane zones

    @Test("the middle of a pane means swap")
    func centreSwaps() {
        #expect(target(250, 300) == .swap(a))
        #expect(target(750, 300) == .swap(b))
    }

    /// The centre of pane A is x 150…350, y 180…420 — the middle 40% of a 500×600 pane.
    /// Every point here is outside it, and outside the 28pt root band.
    @Test("outside the middle, the nearest side wins", arguments: [
        (CGFloat(100), CGFloat(300), Edge.left),
        (420, 300, Edge.right),
        (250, 120, Edge.top),
        (250, 480, Edge.bottom),
    ])
    func edgesOutsideTheCentre(x: CGFloat, y: CGFloat, edge: Edge) {
        #expect(target(x, y) == .edge(a, edge))
    }

    /// The reason the rule is diagonals rather than physical distance: in a pane far wider
    /// than it is tall, a point well inside the left band is still nearer the top in POINTS.
    @Test("a wide pane's top band does not swallow its left band")
    func diagonalsNotDistance() {
        let wide = [a: CGRect(x: 0, y: 0, width: 1000, height: 200)]
        // 100pt from the left, 60pt from the top: nearer the top by distance, but only 10%
        // across the width against 30% down the height.
        let hit = DropZone.target(at: CGPoint(x: 100, y: 60), frames: wide,
                                  canvas: CGRect(x: 0, y: 0, width: 1000, height: 200),
                                  dragged: b)
        #expect(hit == .edge(a, .left))
    }

    @Test("a pane refuses to be dropped on itself")
    func noSelfDrop() {
        #expect(target(250, 300, dragging: a) == nil)
    }

    // MARK: The preview — what will be occupied, not what was hit

    @Test("an edge drop previews HALF the target, not the zone that was hit")
    func edgePreviewIsAHalf() {
        let preview = DropZone.preview(for: .edge(a, .left), frames: frames, canvas: canvas)
        #expect(preview == CGRect(x: 0, y: 0, width: 250, height: 600))
    }

    @Test("a root drop previews half the whole canvas — the full-height sidebar")
    func rootPreviewSpansTheCanvas() {
        let preview = DropZone.preview(for: .root(.left), frames: frames, canvas: canvas)
        #expect(preview == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(preview?.height == canvas.height, "a root split runs the whole side")
    }

    @Test("a swap previews the whole target pane")
    func swapPreviewIsTheWholePane() {
        #expect(DropZone.preview(for: .swap(b), frames: frames, canvas: canvas) == frames[b])
    }
}
