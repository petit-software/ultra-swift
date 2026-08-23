import Testing
import CoreGraphics
@testable import UltraLayout

/// Moving a pane to an edge of the whole tree.
///
/// The thing `move(_:toEdgeOf:edge:)` cannot do: that one splits a target pane, so the moved
/// pane inherits the target's height. A sidebar built that way is only as tall as whichever
/// pane it landed beside, which is why a full-height one could not be reached by dragging.
@Suite("Move to a root edge")
@MainActor
struct RootMoveTests {

    private func grid() -> LayoutTree { .fixture(.grid2x2) }

    /// The whole point, stated as geometry: the moved pane spans the entire side.
    @Test("a pane moved to the root edge runs the full height of the canvas",
          arguments: [Edge.left, .right])
    func spansFullHeight(edge: Edge) {
        var tree = grid()
        let moved = tree.paneIDs[3]
        let didMove = tree.move(moved, toRootEdge: edge)
        #expect(didMove)

        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frames = layout(tree, in: bounds).frames
        let frame = try! #require(frames[moved])
        let tallest = frames.values.map(\.height).max() ?? 0
        #expect(abs(frame.height - tallest) < 1, "a root-edge pane is as tall as the canvas")
        #expect(frame.width < bounds.width / 2)
    }

    @Test("top and bottom span the full width", arguments: [Edge.top, .bottom])
    func spansFullWidth(edge: Edge) {
        var tree = grid()
        let moved = tree.paneIDs[0]
        let didMove = tree.move(moved, toRootEdge: edge)
        #expect(didMove)

        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frames = layout(tree, in: bounds).frames
        let frame = try! #require(frames[moved])
        let widest = frames.values.map(\.width).max() ?? 0
        #expect(abs(frame.width - widest) < 1)
    }

    /// Contrast with the per-pane move, which is the bug this fixes: dropped beside one pane
    /// of a 2×2 grid, a "sidebar" is only half the canvas tall.
    @Test("the per-pane move does NOT span the side — the reason this operation exists")
    func perPaneMoveIsShort() {
        var tree = grid()
        let moved = tree.paneIDs[3]
        let target = tree.paneIDs[0]
        let didMove = tree.move(moved, toEdgeOf: target, edge: .left)
        #expect(didMove)

        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frames = layout(tree, in: bounds).frames
        let frame = try! #require(frames[moved])
        #expect(frame.height < bounds.height * 0.75, "it inherited one pane's height")
    }

    @Test("leading edges put the pane first, trailing edges put it last")
    func ordering() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for (edge, leading) in [(Edge.left, true), (.right, false)] {
            var tree = grid()
            let moved = tree.paneIDs[2]
            let didMove = tree.move(moved, toRootEdge: edge)
        #expect(didMove)
            let frames = layout(tree, in: bounds).frames
            let frame = try! #require(frames[moved])
            let others = frames.filter { $0.key != moved }.values
            if leading {
                #expect(others.allSatisfy { $0.minX >= frame.maxX - 1 })
            } else {
                #expect(others.allSatisfy { $0.maxX <= frame.minX + 1 })
            }
        }
    }

    @Test("the pane count does not change — this is a move, not a split")
    func countIsStable() {
        var tree = grid()
        let before = tree.paneCount
        let didMove = tree.move(tree.paneIDs[1], toRootEdge: .bottom)
        #expect(didMove)
        #expect(tree.paneCount == before)
        #expect(tree.validate().isEmpty, "the tree is left valid")
    }

    @Test("the moved pane takes focus, so the keyboard follows the gesture")
    func movedPaneIsFocused() {
        var tree = grid()
        let moved = tree.paneIDs[2]
        let didMove = tree.move(moved, toRootEdge: .left)
        #expect(didMove)
        #expect(tree.focused == moved)
    }

    /// Wrapping the root around its only pane would produce a container with one real child
    /// and a hole where the other should be.
    @Test("a single-pane tree refuses — there is nothing to move it away from")
    func singlePaneRefuses() {
        var tree = LayoutTree(single: PaneID())
        let refused = tree.move(tree.paneIDs[0], toRootEdge: .left)
        #expect(!refused)
    }

    @Test("a pane that is not in the tree is refused")
    func unknownPaneRefused() {
        var tree = grid()
        let refusedUnknown = tree.move(PaneID(), toRootEdge: .left)
        #expect(!refusedUnknown)
    }

    @Test("every edge leaves a tree that still validates", arguments: Edge.allCases)
    func stayValid(edge: Edge) {
        var tree = grid()
        let didMove = tree.move(tree.paneIDs[1], toRootEdge: edge)
        #expect(didMove)
        #expect(tree.validate().isEmpty)
        #expect(tree.paneCount == 4)
    }
}
