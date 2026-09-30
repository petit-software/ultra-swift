import Testing
import AppKit
@testable import UltraCanvas
@testable import UltraLayout
@testable import UltraCore

/// A tile that persists the layout while it is being built asks the store for its own
/// record before it has one. The store must answer with a stand-in, never by building the
/// pane a second time: that is a recursion with no floor, and it took the app down.
@Suite("Pane surface re-entry")
@MainActor
struct PaneReentryTests {

    @Test("asking for a record from inside its own build does not build it again")
    func reentrantRecordRequestIsAStandIn() {
        var builds = 0
        var store: PaneSurfaceStore!
        store = PaneSurfaceStore { paneID in
            builds += 1
            // What a persist from inside a tile's construction does.
            let seen = store.surfaceRecord(for: paneID)
            #expect(seen.kind == .placeholder)
            return PaneContent(view: NSView(),
                               record: PaneRecord(kind: .editor, title: "Untitled"))
        }
        let paneID = PaneID()

        let record = store.surfaceRecord(for: paneID)

        #expect(builds == 1)
        #expect(record.kind == .editor, "the real record once the build has returned")
        #expect(store.records[paneID]?.title == "Untitled")
        #expect(store.existingSurface(for: paneID) != nil)
    }

    @Test("a pane built once is not built again from outside")
    func recordIsBuiltOnce() {
        var builds = 0
        let store = PaneSurfaceStore { _ in
            builds += 1
            return PaneContent(view: NSView(), record: PaneRecord(kind: .todo, title: "Todo"))
        }
        let paneID = PaneID()
        _ = store.surfaceRecord(for: paneID)
        _ = store.surfaceRecord(for: paneID)
        _ = store.surface(for: paneID)
        #expect(builds == 1)
    }
}
