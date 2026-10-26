import Testing
import Foundation
@testable import UltraLayout

private func pane(_ n: Int) -> PaneID { LayoutTree.fixturePane(n) }

@Suite("Grid")
struct GridTests {

    @Test("counts fill rows as close to square as they can", arguments: [
        (1, [1]), (2, [2]), (3, [2, 1]), (4, [2, 2]), (5, [3, 2]), (6, [3, 3]),
        (7, [3, 3, 1]), (9, [3, 3, 3]), (10, [4, 4, 2]),
    ])
    func shape(count: Int, rows: [Int]) throws {
        let panes = (1...count).map(pane)
        let tree = try #require(LayoutTree.grid(of: panes))
        #expect(tree.validate().isEmpty)
        #expect(tree.paneIDs == panes, "reading order is the order given")
        let shape: [Int]
        if let root = tree.root.asContainer, root.axis == .vertical {
            shape = root.children.map { $0.asContainer?.children.count ?? 1 }
        } else {
            shape = [tree.root.asContainer?.children.count ?? 1]
        }
        #expect(shape == rows)
    }

    @Test("rows and columns are equal shares")
    func equalShares() throws {
        let tree = try #require(LayoutTree.grid(of: (1...6).map(pane)))
        let root = try #require(tree.root.asContainer)
        #expect(root.fractions == [0.5, 0.5])
        for row in root.children {
            #expect(row.asContainer?.fractions.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 } == true)
        }
    }

    @Test("focus is the first pane unless a pane in the grid is asked for")
    func focus() throws {
        let panes = (1...4).map(pane)
        #expect(try #require(LayoutTree.grid(of: panes)).focused == pane(1))
        #expect(try #require(LayoutTree.grid(of: panes, focused: pane(3))).focused == pane(3))
        #expect(try #require(LayoutTree.grid(of: panes, focused: pane(9))).focused == pane(1))
        #expect(LayoutTree.grid(of: []) == nil)
    }
}
