import Testing
import Foundation
import CoreGraphics
@testable import UltraLayout

private func pane(_ n: Int) -> PaneID { LayoutTree.fixturePane(n) }

@Suite("Split")
struct SplitTests {

    @Test("splitting the root leaf turns the root into a container")
    func splitRoot() {
        var tree = LayoutTree(single: pane(1))
        let didSplit = tree.split(pane(1), edge: .right, newPane: pane(2))
        #expect(didSplit)
        let container = try! #require(tree.root.asContainer)
        #expect(container.axis == .horizontal)
        #expect(container.children.count == 2)
        #expect(tree.root.paneIDs == [pane(1), pane(2)])
        #expect(tree.validate().isEmpty)
    }

    @Test("splitting left inserts the new pane before the source")
    func splitBefore() {
        var tree = LayoutTree(single: pane(1))
        tree.split(pane(1), edge: .left, newPane: pane(2))
        #expect(tree.root.paneIDs == [pane(2), pane(1)])
    }

    @Test("a same-axis split takes space ONLY from the source pane")
    func splitTakesOnlyFromSource() {
        // Three across at 0.5 / 0.25 / 0.25, then split the middle one.
        var tree = LayoutTree.fixture(.threeAcross)
        var container = tree.root.asContainer!
        container.fractions = [0.5, 0.25, 0.25]
        tree.root = .container(container)

        tree.split(pane(2), edge: .right, newPane: pane(9), ratio: 0.5)

        let after = tree.root.asContainer!
        #expect(after.children.count == 4)
        // The untouched siblings keep their exact fractions.
        #expect(abs(after.fractions[0] - 0.5) < 1e-9)
        #expect(abs(after.fractions[3] - 0.25) < 1e-9)
        // The source's slot was halved and shared with the new pane.
        #expect(abs(after.fractions[1] - 0.125) < 1e-9)
        #expect(abs(after.fractions[2] - 0.125) < 1e-9)
        #expect(tree.validate().isEmpty)
    }

    @Test("a perpendicular split wraps the leaf in place")
    func perpendicularSplit() {
        var tree = LayoutTree.fixture(.threeAcross)
        tree.split(pane(2), edge: .bottom, newPane: pane(9))

        let row = tree.root.asContainer!
        #expect(row.children.count == 3)
        let wrapped = try! #require(row.children[1].asContainer)
        #expect(wrapped.axis == .vertical)
        #expect(wrapped.paneIDs == [pane(2), pane(9)])
        #expect(tree.validate().isEmpty)
    }

    @Test("repeated same-direction splits stay flat, never a right-leaning chain")
    func repeatedSplitsStayFlat() {
        var tree = LayoutTree(single: pane(1))
        for n in 2...6 { tree.split(pane(n - 1), edge: .right, newPane: pane(n)) }

        let container = try! #require(tree.root.asContainer)
        #expect(container.children.count == 6)
        #expect(container.children.allSatisfy { $0.asLeaf != nil })
        #expect(tree.validate().isEmpty)
    }

    @Test("splitting with a pane already in the tree is refused")
    func rejectsDuplicate() {
        var tree = LayoutTree.fixture(.twoAcross)
        let didSplit = tree.split(pane(1), edge: .right, newPane: pane(2))
        #expect(!didSplit)
    }

    @Test("split focuses the new pane and clears zoom")
    func splitFocus() {
        var tree = LayoutTree.fixture(.twoAcross)
        tree.toggleZoom(pane(1))
        tree.split(pane(1), edge: .right, newPane: pane(9))
        #expect(tree.focused == pane(9))
        #expect(tree.zoomed == nil)
    }
}

@Suite("Close")
struct CloseTests {

    @Test("the last pane cannot be closed")
    func lastPane() {
        var tree = LayoutTree(single: pane(1))
        let didClose = tree.close(pane(1))
        #expect(!didClose)
        #expect(tree.paneCount == 1)
    }

    @Test("closing redistributes proportionally, preserving relative sizes")
    func proportionalRedistribution() {
        var tree = LayoutTree.fixture(.threeAcross)
        var container = tree.root.asContainer!
        container.fractions = [0.2, 0.5, 0.3]   // survivors are 2:3
        tree.root = .container(container)

        tree.close(pane(2))

        let after = tree.root.asContainer!
        #expect(after.children.count == 2)
        #expect(abs(after.fractions[0] - 0.4) < 1e-9)   // 0.2 / 0.5
        #expect(abs(after.fractions[1] - 0.6) < 1e-9)   // 0.3 / 0.5
    }

    @Test("closing returns space to the pane it was split from, leaving others untouched")
    func spaceReturnsToOrigin() {
        var tree = LayoutTree.fixture(.threeAcross)
        var container = tree.root.asContainer!
        container.fractions = [0.5, 0.25, 0.25]
        tree.root = .container(container)

        tree.split(pane(1), edge: .right, newPane: pane(9), ratio: 0.4)
        tree.close(pane(9))

        let after = tree.root.asContainer!
        #expect(after.children.count == 3)
        #expect(abs(after.fractions[0] - 0.5) < 1e-9)    // the source got it all back
        #expect(abs(after.fractions[1] - 0.25) < 1e-9)   // untouched
        #expect(abs(after.fractions[2] - 0.25) < 1e-9)   // untouched
    }

    @Test("a container left with one child collapses into its parent")
    func collapsesSingleChild() {
        var tree = LayoutTree.fixture(.grid2x2)
        tree.close(pane(2))     // top row now has one child
        // The surviving top pane must be a direct child of the column, not a 1-child row.
        let column = try! #require(tree.root.asContainer)
        #expect(column.axis == .vertical)
        #expect(column.children[0].asLeaf?.paneID == pane(1))
        #expect(tree.validate().isEmpty)
    }

    @Test("collapsing that exposes a same-axis nesting flattens it")
    func collapseThenFlatten() {
        // row[ p1, column[ p2, row[p3, p4] ] ] — closing p2 leaves a row inside a row.
        var tree = LayoutTree(root: .container(Container(axis: .horizontal, children: [
            .pane(pane(1)),
            .container(Container(axis: .vertical, children: [
                .pane(pane(2)),
                .container(Container(axis: .horizontal, children: [.pane(pane(3)), .pane(pane(4))])),
            ])),
        ])), focused: pane(1))

        tree.close(pane(2))

        let row = try! #require(tree.root.asContainer)
        #expect(row.axis == .horizontal)
        #expect(row.paneIDs == [pane(1), pane(3), pane(4)])
        #expect(row.children.allSatisfy { $0.asLeaf != nil })
        #expect(tree.validate().isEmpty)
    }

    @Test("closing the focused pane moves focus to a neighbour")
    func focusMoves() {
        var tree = LayoutTree.fixture(.threeAcross)
        tree.focused = pane(2)
        tree.close(pane(2))
        #expect(tree.contains(tree.focused))
        #expect(tree.focused == pane(3))
    }
}

@Suite("Resize")
struct ResizeTests {
    let metrics = LayoutMetrics.default

    @Test("a divider moves exactly two neighbours")
    func movesTwoNeighbours() {
        var tree = LayoutTree.fixture(.threeAcross)
        let ref = DividerRef(containerID: tree.root.id, index: 0)
        let applied = tree.resize(divider: ref, by: 100, containerSize: 900, minPaneSize: 100)

        #expect(abs(applied - 100) < 1e-6)
        let f = tree.root.asContainer!.fractions
        #expect(abs(f[0] - (1.0 / 3 + 100.0 / 900)) < 1e-9)
        #expect(abs(f[1] - (1.0 / 3 - 100.0 / 900)) < 1e-9)
        #expect(abs(f[2] - 1.0 / 3) < 1e-9)          // untouched
        #expect(abs(f.reduce(0, +) - 1) < 1e-9)
    }

    @Test("hard stop clamps at the minimum and reports the delta it could apply")
    func hardStop() {
        var tree = LayoutTree.fixture(.twoAcross)
        let ref = DividerRef(containerID: tree.root.id, index: 0)
        // Each pane starts at 500pt of 1000. The neighbour can give up 400 before hitting 100.
        let applied = tree.resize(divider: ref, by: 900, containerSize: 1000, minPaneSize: 100)

        #expect(abs(applied - 400) < 1e-6)
        let f = tree.root.asContainer!.fractions
        #expect(abs(f[1] - 0.1) < 1e-9)
        #expect(abs(f.reduce(0, +) - 1) < 1e-9)
    }

    @Test("hard stop does NOT cascade into the next divider")
    func noCascade() {
        var tree = LayoutTree.fixture(.threeAcross)
        let ref = DividerRef(containerID: tree.root.id, index: 0)
        tree.resize(divider: ref, by: 5000, containerSize: 900, minPaneSize: 90)
        let f = tree.root.asContainer!.fractions
        #expect(abs(f[2] - 1.0 / 3) < 1e-9)   // the far sibling never moved
    }

    @Test("push mode consumes slack from successive siblings")
    func pushCascades() {
        var tree = LayoutTree.fixture(.threeAcross)
        let ref = DividerRef(containerID: tree.root.id, index: 0)
        tree.resize(divider: ref, by: 5000, containerSize: 900, minPaneSize: 90,
                    mode: .push)
        let f = tree.root.asContainer!.fractions
        #expect(abs(f[1] - 0.1) < 1e-9)
        #expect(abs(f[2] - 0.1) < 1e-9)
        #expect(abs(f[0] - 0.8) < 1e-9)
        #expect(abs(f.reduce(0, +) - 1) < 1e-9)
    }

    @Test("fractions still sum to 1 after a thousand jittery drags")
    func noDrift() {
        var tree = LayoutTree.fixture(.threeAcross)
        var rng = SeededRNG(seed: 99)
        for _ in 0..<1000 {
            let index = Int(rng.next() % 2)
            let delta = CGFloat(Int(rng.next() % 200)) - 100
            tree.resize(divider: DividerRef(containerID: tree.root.id, index: index),
                        by: delta, containerSize: 900, minPaneSize: 60)
        }
        #expect(tree.validate().isEmpty)
    }
}

@Suite("Zoom, swap, move")
struct StructuralTests {

    @Test("zoom is non-destructive — un-zooming restores identical geometry")
    func zoomRoundTrip() {
        let original = LayoutTree.fixture(.deepNest)
        var tree = original
        tree.toggleZoom(pane(3))
        #expect(tree.zoomed == pane(3))
        #expect(tree.root == original.root)       // the tree itself is untouched
        tree.toggleZoom(pane(3))
        #expect(tree == original)
    }

    @Test("swap exchanges two panes in place")
    func swap() {
        var tree = LayoutTree.fixture(.threeAcross)
        let didSwap = tree.swap(pane(1), pane(3))
        #expect(didSwap)
        #expect(tree.root.paneIDs == [pane(3), pane(2), pane(1)])
    }

    @Test("move is close-then-split, and leaves the pane focused")
    func move() {
        var tree = LayoutTree.fixture(.grid2x2)
        let didMove = tree.move(pane(4), toEdgeOf: pane(1), edge: .left)
        #expect(didMove)
        #expect(tree.focused == pane(4))
        #expect(tree.paneCount == 4)
        #expect(tree.validate().isEmpty)
    }

    @Test("equalize affects only the named container")
    func equalizeOne() {
        var tree = LayoutTree.fixture(.sidebarMain)
        let column = tree.root.asContainer!.children[1].asContainer!
        tree.equalize(container: column.id)
        #expect(tree.root.asContainer!.fractions == [0.25, 0.75])   // outer row untouched
        let after = tree.root.asContainer!.children[1].asContainer!
        #expect(after.fractions.allSatisfy { abs($0 - 0.5) < 1e-9 })
    }
}

@Suite("Codable")
struct CodableTests {
    @Test("every fixture round-trips byte-stably", arguments: LayoutTree.Fixture.allCases)
    func roundTrip(fixture: LayoutTree.Fixture) throws {
        let tree = LayoutTree.fixture(fixture)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let once = try encoder.encode(tree)
        let decoded = try JSONDecoder().decode(LayoutTree.self, from: once)
        #expect(decoded == tree)
        #expect(try encoder.encode(decoded) == once)
    }
}

/// Deterministic PRNG so property-test failures reproduce exactly.
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 16
    }
    mutating func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
    mutating func double() -> Double { Double(next() % 10_000) / 10_000 }
}
