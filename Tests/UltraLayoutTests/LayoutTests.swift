import Testing
import Foundation
import CoreGraphics
@testable import UltraLayout

private func pane(_ n: Int) -> PaneID { LayoutTree.fixturePane(n) }
private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

/// Every edge of every frame must land on the backing-store pixel grid.
private func isPixelSnapped(_ rect: CGRect, scale: CGFloat) -> Bool {
    [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy {
        abs($0 * scale - ($0 * scale).rounded()) < 1e-6
    }
}

@Suite("Layout geometry")
struct LayoutGeometryTests {

    @Test("frames never overlap", arguments: LayoutTree.Fixture.allCases)
    func noOverlaps(fixture: LayoutTree.Fixture) {
        let frames = Array(layout(LayoutTree.fixture(fixture), in: bounds).frames.values)
        for i in frames.indices {
            for j in frames.indices where j > i {
                let overlap = frames[i].intersection(frames[j])
                #expect(overlap.isNull || overlap.width < 0.01 || overlap.height < 0.01,
                        "\(frames[i]) overlaps \(frames[j])")
            }
        }
    }

    @Test("panes exactly fill the padded canvas — the last pane is never a pixel short",
          arguments: LayoutTree.Fixture.allCases)
    func exactCoverage(fixture: LayoutTree.Fixture) {
        let metrics = LayoutMetrics.default
        let result = layout(LayoutTree.fixture(fixture), in: bounds, metrics: metrics)
        let union = result.frames.values.reduce(CGRect.null) { $0.union($1) }
        let expected = metrics.contentRect(in: bounds)
        #expect(abs(union.minX - expected.minX) < 0.01)
        #expect(abs(union.minY - expected.minY) < 0.01)
        #expect(abs(union.maxX - expected.maxX) < 0.01)
        #expect(abs(union.maxY - expected.maxY) < 0.01)
    }

    @Test("every edge is pixel-snapped", arguments: [CGFloat(1), 2, 3])
    func pixelSnapping(scale: CGFloat) {
        var metrics = LayoutMetrics.default
        metrics.scale = scale
        // A width that does not divide evenly, to force rounding everywhere.
        let odd = CGRect(x: 0, y: 0, width: 1003.7, height: 677.3)
        for fixture in LayoutTree.Fixture.allCases {
            let result = layout(LayoutTree.fixture(fixture), in: odd, metrics: metrics)
            for (id, frame) in result.frames {
                #expect(isPixelSnapped(frame, scale: scale), "\(fixture) pane \(id) at \(frame)")
            }
        }
    }

    @Test("siblings are separated by exactly one gutter")
    func gutters() {
        let metrics = LayoutMetrics.default
        let result = layout(.fixture(.threeAcross), in: bounds, metrics: metrics)
        let ordered = (1...3).map { result.frames[pane($0)]! }
        #expect(abs(ordered[0].maxX + metrics.gutter - ordered[1].minX) < 0.01)
        #expect(abs(ordered[1].maxX + metrics.gutter - ordered[2].minX) < 0.01)
        // Full height, no vertical gutter in a row.
        #expect(ordered.allSatisfy { abs($0.height - metrics.contentRect(in: bounds).height) < 0.01 })
    }

    @Test("equal fractions produce equal panes")
    func equalWidths() {
        let result = layout(.fixture(.threeAcross), in: bounds)
        let widths = (1...3).map { result.frames[pane($0)]!.width }
        #expect(abs(widths[0] - widths[1]) <= 0.5)
        #expect(abs(widths[1] - widths[2]) <= 0.5)
    }

    @Test("golden frames — sidebar + main at 1200×800")
    func golden() {
        let result = layout(.fixture(.sidebarMain), in: bounds)
        // padded content: padding 8 + edgeInset 4 on left/right/bottom, and NOTHING on
        // top — the toolbar's layout rect already holds the panes off that edge, so padding
        // there reads as a second gap. x 12…1188 (1176 wide), y 0…788 (788 tall);
        // row gutter 12 -> 1164 usable.
        #expect(result.frames[pane(1)]!.width == 291)             // 0.25 * 1164
        #expect(result.frames[pane(2)]!.minX == 315)              // 12 + 291 + 12
        #expect(result.frames[pane(2)]!.maxX == 1188)
        // The top pane starts flush against the top of the canvas.
        #expect(result.frames[pane(1)]!.minY == 0)
        // column: 788 tall, one gutter -> 776 usable, split 0.7 / 0.3
        #expect(result.frames[pane(2)]!.height == 543)            // 0.7 * 776, pixel-snapped
        #expect(result.frames[pane(3)]!.maxY == 788)
    }

    /// The toolbar's content layout rect already holds the panes off the window's top
    /// edge. Padding there as well reads as a double gap under the toolbar, so the top
    /// inset is deliberately zero while the other three edges keep theirs.
    @Test("panes sit flush against the top of the canvas")
    func topEdgeIsFlush() {
        let metrics = LayoutMetrics.default
        #expect(metrics.topPadding == 0)

        let content = metrics.contentRect(in: bounds)
        #expect(content.minY == bounds.minY)
        // The other three edges are unaffected.
        #expect(content.minX == bounds.minX + metrics.padding + metrics.edgeInset)
        #expect(content.maxX == bounds.maxX - metrics.padding - metrics.edgeInset)
        #expect(content.maxY == bounds.maxY - metrics.padding - metrics.edgeInset)

        for fixture in LayoutTree.Fixture.allCases {
            let frames = layout(.fixture(fixture), in: bounds, metrics: metrics).frames
            #expect(frames.values.map(\.minY).min() == bounds.minY,
                    "\(fixture) leaves a gap above the topmost pane")
        }
    }

    @Test("dividers sit in the gutter with a generous hit area")
    func dividerFrames() {
        let metrics = LayoutMetrics.default
        let result = layout(.fixture(.twoAcross), in: bounds, metrics: metrics)
        let divider = try! #require(result.dividers.first)
        #expect(divider.axis == .horizontal)
        #expect(divider.lineRect.width == metrics.dividerLineWidth)
        #expect(divider.hitRect.width >= metrics.dividerHitWidth)
        #expect(divider.hitRect.contains(CGPoint(x: divider.lineRect.midX, y: 400)))
        #expect(abs(divider.fraction - 0.5) < 1e-9)
    }

    @Test("a zoomed pane takes the whole canvas and hides the rest")
    func zoom() {
        var tree = LayoutTree.fixture(.grid2x2)
        tree.toggleZoom(pane(3))
        let result = layout(tree, in: bounds)
        #expect(result.frames.count == 1)
        #expect(result.hidden == Set([pane(1), pane(2), pane(4)]))
        #expect(result.frames[pane(3)] == LayoutMetrics.default.contentRect(in: bounds))
    }

    @Test("visual order is reading order, not tree order")
    func visualOrder() {
        var tree = LayoutTree.fixture(.grid2x2)
        tree.swap(pane(1), pane(4))     // tree order now 4,2,3,1
        let order = layout(tree, in: bounds).visualOrder
        #expect(order == [pane(4), pane(2), pane(3), pane(1)])  // still top-left → bottom-right
    }

    @Test("a degenerate canvas produces no frames rather than NaNs")
    func degenerate() {
        let result = layout(.fixture(.grid2x2), in: CGRect(x: 0, y: 0, width: 4, height: 4))
        #expect(result.frames.isEmpty)
    }

    @Test("canSplit refuses a split that would produce an unusable pane")
    func splitGuard() {
        let tree = LayoutTree.fixture(.single)
        #expect(canSplit(tree, pane: pane(1), edge: .right, in: bounds))
        let narrow = CGRect(x: 0, y: 0, width: 300, height: 800)
        #expect(!canSplit(tree, pane: pane(1), edge: .right, in: narrow))  // 160pt minimum
        #expect(canSplit(tree, pane: pane(1), edge: .bottom, in: narrow))  // 80pt minimum
    }
}

@Suite("Spatial navigation")
struct NavigationTests {
    let frames = layout(.fixture(.grid2x2), in: bounds).frames

    @Test("moves in the direction pressed, in a grid")
    func gridMoves() {
        #expect(focusTarget(from: pane(1), direction: .right, frames: frames) == pane(2))
        #expect(focusTarget(from: pane(2), direction: .left, frames: frames) == pane(1))
        #expect(focusTarget(from: pane(1), direction: .bottom, frames: frames) == pane(3))
        #expect(focusTarget(from: pane(4), direction: .top, frames: frames) == pane(2))
    }

    @Test("does not wrap around at the edge")
    func noWrap() {
        #expect(focusTarget(from: pane(1), direction: .left, frames: frames) == nil)
        #expect(focusTarget(from: pane(4), direction: .bottom, frames: frames) == nil)
    }

    @Test("prefers the overlapping neighbour over a merely closer one")
    func prefersOverlap() {
        // A tall sidebar on the left; two stacked panes on the right.
        let frames: [PaneID: CGRect] = [
            pane(1): CGRect(x: 0, y: 0, width: 200, height: 400),      // sidebar
            pane(2): CGRect(x: 206, y: 0, width: 400, height: 100),    // top right
            pane(3): CGRect(x: 206, y: 106, width: 400, height: 294),  // bottom right, overlaps more
        ]
        // From the sidebar, both right-hand panes overlap; the larger overlap wins.
        #expect(focusTarget(from: pane(1), direction: .right, frames: frames) == pane(3))
    }

    @Test("falls back to the nearest centre when nothing overlaps")
    func fallback() {
        let frames: [PaneID: CGRect] = [
            pane(1): CGRect(x: 0, y: 0, width: 100, height: 100),
            pane(2): CGRect(x: 300, y: 500, width: 100, height: 100),
            pane(3): CGRect(x: 300, y: 900, width: 100, height: 100),
        ]
        #expect(focusTarget(from: pane(1), direction: .right, frames: frames) == pane(2))
    }

    @Test("directional memory makes ← → round-trip")
    func memory() {
        // Wide pane on the left, two stacked on the right. Going right lands on the
        // bigger one; coming back left, then right again must return to it.
        let frames: [PaneID: CGRect] = [
            pane(1): CGRect(x: 0, y: 0, width: 200, height: 400),
            pane(2): CGRect(x: 206, y: 0, width: 400, height: 300),
            pane(3): CGRect(x: 206, y: 306, width: 400, height: 94),
        ]
        var memory = NavigationMemory()
        // Deliberately enter the SMALL pane, which geometry alone would not pick.
        memory.record(from: pane(1), to: pane(3), edge: .right)
        #expect(focusTarget(from: pane(3), direction: .left, frames: frames, memory: memory) == pane(1))

        memory.record(from: pane(3), to: pane(1), edge: .left)
        #expect(focusTarget(from: pane(1), direction: .right, frames: frames, memory: memory) == pane(3))
    }

    @Test("a remembered target that is no longer a candidate is ignored")
    func staleMemory() {
        var memory = NavigationMemory()
        memory.record(from: pane(2), to: pane(1), edge: .right)   // claims 1 is right of 2
        // In the real grid, pane 1 is LEFT of pane 2, so the memory must be discarded.
        #expect(focusTarget(from: pane(2), direction: .right, frames: frames, memory: memory) != pane(1))
    }

    @Test("⌃⌘→ picks the divider on the focused pane's right edge")
    func nearestDivider() {
        let tree = LayoutTree.fixture(.threeAcross)
        let result = layout(tree, in: bounds)
        let right = try! #require(tree.nearestDivider(to: pane(2), edge: .right, in: result))
        let left = try! #require(tree.nearestDivider(to: pane(2), edge: .left, in: result))
        #expect(right.ref.index == 1)
        #expect(left.ref.index == 0)
    }
}
