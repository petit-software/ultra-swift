import Testing
import AppKit
import Foundation
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout

/// A window holds several whole canvases now, and switching between them must not disturb
/// what is running in the ones you cannot see.
///
/// These exercise `LayoutStore` directly rather than `SessionList`, which lives in the app
/// target and has no test target of its own. What they cover is the property the whole
/// feature rests on: a pane's surface is owned ABOVE the view layer, so tearing a canvas
/// down and building another leaves the panes — and their processes — untouched.
@Suite("Sessions hold whole canvases")
@MainActor
struct SessionCanvasTests {

    @MainActor
    private final class CountingFactory {
        var builds: [PaneID: Int] = [:]
        func make(_ paneID: PaneID) -> PaneContent {
            builds[paneID, default: 0] += 1
            return PaneContent(view: NSView(),
                               record: PaneRecord(kind: .placeholder, title: "Pane"))
        }
    }

    private func store(_ fixture: LayoutTree.Fixture) -> (LayoutStore, CountingFactory) {
        let factory = CountingFactory()
        let store = LayoutStore(tree: .fixture(fixture)) { factory.make($0) }
        store.canvasBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        return (store, factory)
    }

    private func mount(_ store: LayoutStore) -> (SplitCanvasView, NSWindow) {
        let canvas = SplitCanvasView(store: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        canvas.sync()
        canvas.layoutSubtreeIfNeeded()
        return (canvas, window)
    }

    /// The claim the sidebar rests on: switching sessions tears the canvas down, and the
    /// panes survive it. If this failed, every switch would restart every shell.
    @Test("tearing a canvas down and building another does not rebuild a single pane")
    func switchingSessionsKeepsPanes() {
        let (store, factory) = store(.grid2x2)
        var (canvas, window) = mount(store)

        let panes = store.tree.paneIDs
        #expect(panes.count == 4)
        let surfaces = panes.compactMap { store.surfaces.existingSurface(for: $0) }
        #expect(surfaces.count == 4)
        for paneID in panes { #expect(factory.builds[paneID] == 1) }

        // What switching away and back does: this canvas goes, another arrives on the same
        // store. `CanvasSurface` drives it with `.id(store.workspaceID)`.
        window.contentView = NSView()
        canvas.removeFromSuperview()
        (canvas, window) = mount(store)

        for paneID in panes {
            #expect(factory.builds[paneID] == 1, "a pane was rebuilt — its process would be gone")
        }
        // The SAME view objects, not equivalent ones. A shell's PTY lives in this view.
        for (index, paneID) in panes.enumerated() {
            #expect(store.surfaces.existingSurface(for: paneID) === surfaces[index])
        }
        _ = window
    }

    @Test("a session that is not on screen keeps its panes alive")
    func hiddenSessionKeepsItsPanes() {
        let (visible, _) = store(.twoAcross)
        let (hidden, hiddenFactory) = store(.grid2x2)

        _ = mount(visible)
        // The hidden session is never mounted at all — its panes are materialised by the
        // sidebar asking for a record, which is what a row's pane count does.
        for paneID in hidden.tree.paneIDs { _ = hidden.surfaces.surfaceRecord(for: paneID) }

        #expect(hidden.surfaces.activePanes.count == 4)
        #expect(hiddenFactory.builds.values.allSatisfy { $0 == 1 })
    }

    /// Closing a session is the ONLY thing that stops its shells. `SessionList.close` routes
    /// through `ShellWorkspace.tearDown`, which prunes to nothing — this is that step.
    @Test("closing a session releases every pane exactly once")
    func closingASessionReleasesEveryPane() {
        let (store, _) = store(.grid2x2)
        _ = mount(store)
        var released: [PaneID] = []
        store.surfaces.onRelease = { released.append($0) }

        let panes = store.tree.paneIDs
        store.surfaces.prune(keeping: [])

        #expect(Set(released) == Set(panes))
        #expect(released.count == panes.count, "a pane released twice is a PTY killed twice")
        #expect(store.surfaces.activePanes.isEmpty)
    }

    /// Each session is its own canvas: two of them must not share panes, records, or focus.
    @Test("two sessions keep entirely separate panes")
    func sessionsDoNotShareState() {
        let (first, _) = store(.twoAcross)
        let (second, _) = store(.grid2x2)
        _ = mount(first)
        _ = mount(second)

        #expect(first.workspaceID != second.workspaceID)
        // Compared by SURFACE, not by id. The layout fixtures issue deterministic `PaneID`s,
        // so two fixture-built sessions do share id VALUES — which is harmless, because each
        // store keys its own surfaces. What must never be shared is the view a pane's process
        // lives in, and that is what this checks.
        let shared = first.tree.paneIDs.contains { paneID in
            guard let mine = first.surfaces.existingSurface(for: paneID),
                  let theirs = second.surfaces.existingSurface(for: paneID) else { return false }
            return mine === theirs
        }
        #expect(!shared, "two sessions must never point at one pane view")

        first.focus(first.tree.paneIDs[1])
        #expect(second.tree.focused != first.tree.focused)
    }
}
