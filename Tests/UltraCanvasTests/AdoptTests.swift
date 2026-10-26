import Testing
import AppKit
import Foundation
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout

/// A whole new arrangement keeps the panes it still names: their surfaces, and so their
/// processes. See `LayoutStore.adopt(tree:)`.
@Suite("Adopting a layout")
@MainActor
struct AdoptTests {

    @Test("panes the new tree still names keep their surfaces; the rest are released once")
    func keepsSurvivors() {
        let factory = CountingFactory()
        let store = LayoutStore(tree: .fixture(.threeAcross)) { factory.make($0) }
        var released: [PaneID] = []
        store.surfaces.onRelease = { released.append($0) }
        let panes = store.tree.paneIDs
        let views = panes.map { store.surfaces.surface(for: $0) }

        let fresh = PaneID()
        var next = LayoutTree(single: panes[2])
        next.split(panes[2], edge: .left, newPane: panes[0])
        next.split(panes[2], edge: .bottom, newPane: fresh)
        store.adopt(tree: next)

        #expect(released == [panes[1]])
        #expect(store.surfaces.existingSurface(for: panes[0]) === views[0])
        #expect(store.surfaces.existingSurface(for: panes[2]) === views[2])
        #expect(store.surfaces.existingSurface(for: panes[1]) == nil)
        #expect(factory.builds[panes[0]] == 1 && factory.builds[panes[2]] == 1)
        _ = store.surfaces.surface(for: fresh)
        #expect(factory.builds[fresh] == 1)
    }

    @Test("a tree naming none of the old panes releases every one, as before")
    func releasesAll() {
        let factory = CountingFactory()
        let store = LayoutStore(tree: .fixture(.twoAcross)) { factory.make($0) }
        var released: [PaneID] = []
        store.surfaces.onRelease = { released.append($0) }
        for pane in store.tree.paneIDs { _ = store.surfaces.surface(for: pane) }

        store.adopt(tree: LayoutTree(single: PaneID()))
        #expect(Set(released) == Set(LayoutTree.fixture(.twoAcross).paneIDs))
        #expect(store.surfaces.activePanes.isEmpty)
    }
}
