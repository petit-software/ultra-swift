import Testing
import AppKit
import CoreGraphics
import Foundation
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout

/// A pane lent to another canvas and brought back: the same view all the way, the home
/// keeping its place with a stand-in meanwhile. See `LayoutStore.send(_:toVisit:)`.
@Suite("Visiting panes")
@MainActor
struct VisitingPaneTests {

    /// A session's canvas in a window, with the counting factory and the release log the
    /// pane window tests use.
    @MainActor
    private final class Session {
        let factory = CountingFactory()
        let store: LayoutStore
        let canvas: SplitCanvasView
        var released: [PaneID] = []

        init(_ fixture: LayoutTree.Fixture) {
            let factory = factory
            store = LayoutStore(tree: .fixture(fixture)) { factory.make($0) }
            canvas = Self.host(store)
            store.surfaces.onRelease = { [unowned self] in released.append($0) }
        }

        static func host(_ store: LayoutStore) -> SplitCanvasView {
            let canvas = SplitCanvasView(store: store)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            window.contentView = canvas
            canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
            canvas.layoutSubtreeIfNeeded()
            return canvas
        }

        func settle() {
            canvas.sync()
            canvas.layoutSubtreeIfNeeded()
        }
    }

    /// The overview: a host canvas whose tree is set by hand, the way the app computes a
    /// grid. It opens on a placeholder pane of its own — a tree cannot be empty — which
    /// is the one thing its factory is ever asked to build.
    @MainActor
    private final class Overview {
        let placeholder = PaneID()
        let store: LayoutStore
        let canvas: SplitCanvasView
        private let counter: Counter
        var built: Int { counter.count }
        var left: [PaneID] = []

        @MainActor final class Counter { var count = 0 }

        init() {
            let counter = Counter()
            store = LayoutStore(tree: LayoutTree(single: placeholder)) { _ in
                counter.count += 1
                return PaneContent(view: NSView(), record: PaneRecord(kind: .placeholder, title: "?"))
            }
            self.counter = counter
            canvas = Session.host(store)
            store.onVisitorLeft = { [unowned self] in left.append($0) }
            // How the app wires a host: a pane closed here is closed at home.
            store.surfaces.onRelease = { [unowned self] in store.visitorClosed($0) }
        }

        func settle() {
            canvas.sync()
            canvas.layoutSubtreeIfNeeded()
        }

        /// Show these panes side by side, as the app does once they have been lent.
        func show(_ panes: [PaneID]) {
            var grid = LayoutTree(single: panes[0])
            for pane in panes.dropFirst() { grid.split(grid.focused, edge: .right, newPane: pane) }
            store.rearrange(grid)
            settle()
        }
    }

    @Test("a lent pane keeps its view on the host and leaves a stand-in at home; nothing is built or released")
    func lendKeepsTheView() throws {
        let session = Session(.threeAcross)
        session.settle()
        let pane = session.store.tree.paneIDs[1]
        let view = session.store.surfaces.surface(for: pane)
        let overview = Overview()

        #expect(session.store.send(pane, toVisit: overview.store))
        session.settle()
        overview.show([pane])

        #expect(session.store.tree.contains(pane), "the tree keeps the pane's place")
        #expect(overview.store.surfaces.existingSurface(for: pane) === view)
        #expect(view.window === overview.canvas.window, "the pane is on screen on the host")
        let standIn = try #require(session.store.surfaces.existingSurface(for: pane))
        #expect(standIn !== view)
        #expect(standIn.window === session.canvas.window, "the stand-in is on screen at home")
        #expect(session.store.surfaces.liveSurface(for: pane) === view)
        #expect(session.store.visitingPanes[pane] === overview.store)
        #expect(overview.store.home(of: pane) === session.store)
        #expect(session.store.holder(of: pane) === overview.store)
        #expect(session.factory.builds[pane] == 1)
        #expect(overview.built == 1, "the placeholder, and nothing for the visitor")
        #expect(session.released.isEmpty)
        #expect(!session.store.send(pane, toVisit: overview.store), "a pane away cannot be lent again")
    }

    @Test("taking a pane home puts the same view back where it was and drops the stand-in")
    func takeHome() throws {
        let session = Session(.grid2x2)
        session.settle()
        let before = session.store.tree
        let pane = before.paneIDs[2]
        let view = session.store.surfaces.surface(for: pane)
        let overview = Overview()
        try #require(session.store.send(pane, toVisit: overview.store))
        session.settle()
        overview.show([pane])
        let standIn = session.store.surfaces.existingSurface(for: pane)

        #expect(session.store.takeHome(pane))
        session.settle()

        #expect(session.store.tree == before)
        #expect(session.store.surfaces.existingSurface(for: pane) === view)
        #expect(view.window === session.canvas.window)
        #expect(standIn?.superview == nil, "the stand-in has left the canvas")
        #expect(session.store.visitingPanes.isEmpty)
        #expect(overview.store.visitors.isEmpty)
        #expect(overview.left == [pane], "the host is told")
        #expect(session.factory.builds[pane] == 1)
        #expect(session.released.isEmpty)
        #expect(!session.store.takeHome(pane), "a pane at home has nowhere to come back from")
    }

    @Test("the host rearranging its tree after a pane went home releases nothing")
    func rearrangeAfterReturn() throws {
        let session = Session(.twoAcross)
        session.settle()
        let panes = session.store.tree.paneIDs
        let overview = Overview()
        try #require(session.store.send(panes[0], toVisit: overview.store))
        try #require(session.store.send(panes[1], toVisit: overview.store))
        overview.show(panes)
        #expect(overview.store.surfaces.activePanes == Set(panes))

        session.store.takeHome(panes[0])
        overview.show([panes[1]])
        session.settle()

        #expect(session.released.isEmpty)
        #expect(overview.store.surfaces.activePanes == [panes[1]])
        #expect(session.store.surfaces.existingSurface(for: panes[0])?.window === session.canvas.window)
    }

    @Test("closing a pane on the host stops it once and takes it out of the home's tree")
    func closeOnHost() throws {
        let session = Session(.threeAcross)
        session.settle()
        let pane = session.store.tree.paneIDs[0]
        let overview = Overview()
        try #require(session.store.send(pane, toVisit: overview.store))
        overview.show([pane, overview.placeholder])
        session.settle()

        overview.store.close(pane)
        session.settle()

        #expect(session.released == [pane])
        #expect(!session.store.tree.contains(pane))
        #expect(session.store.tree.paneCount == 2)
        #expect(session.store.surfaces.existingSurface(for: pane) == nil, "no stand-in left behind")
        #expect(session.store.visitingPanes.isEmpty)
        #expect(overview.store.visitors.isEmpty)
    }

    @Test("a pane that is the last of its canvas cannot be closed on the host")
    func lastPaneLockedOpen() throws {
        let session = Session(.single)
        session.settle()
        let pane = session.store.tree.focused
        let overview = Overview()
        try #require(session.store.send(pane, toVisit: overview.store))
        let other = overview.placeholder
        overview.store.surfaces.lockedOpen = [pane]
        overview.show([pane, other])

        overview.store.close(pane)
        overview.settle()

        #expect(overview.store.tree.contains(pane))
        #expect(session.released.isEmpty)
        #expect(overview.store.surfaces.existingSurface(for: pane)?.canClose == false)
        #expect(overview.store.surfaces.existingSurface(for: other)?.canClose == true)
    }

    @Test("the home closing while a pane is away evicts it from the host, stopping it once")
    func homeReleasesWhileAway() throws {
        let session = Session(.twoAcross)
        session.settle()
        let pane = session.store.tree.paneIDs[1]
        let overview = Overview()
        try #require(session.store.send(pane, toVisit: overview.store))
        overview.show([pane])

        // What `ShellWorkspace.tearDown` does to a session's panes.
        session.store.surfaces.prune(keeping: [])

        #expect(session.released.contains(pane))
        #expect(session.released.count == 2)
        #expect(overview.store.surfaces.existingSurface(for: pane) == nil)
        #expect(overview.store.visitors.isEmpty)
        #expect(overview.left == [pane], "the host is told to take it off its tree")
    }

    @Test("the home's document carries the record the host is showing for an away pane")
    func documentWhileAway() throws {
        let session = Session(.twoAcross)
        session.settle()
        let pane = session.store.tree.paneIDs[0]
        let overview = Overview()
        try #require(session.store.send(pane, toVisit: overview.store))

        // A shell reporting a new folder reaches the canvas holding the pane.
        let holder = try #require(session.store.holder(of: pane))
        holder.surfaces.updateRecord(PaneRecord(kind: .shell, title: "~/Repo/other", cwd: "/Users/x/Repo/other"),
                                     for: pane)

        let document = session.store.document
        #expect(document.isConsistent)
        #expect(document.tree.contains(pane))
        #expect(document.record(for: pane)?.cwd == "/Users/x/Repo/other")
        #expect(session.factory.builds[pane] == 1)
    }

    @Test("a pane in a pane window can visit too, and goes back to that window")
    func fromPaneWindow() throws {
        let session = Session(.twoAcross)
        session.settle()
        let pane = session.store.tree.paneIDs[0]
        let view = session.store.surfaces.surface(for: pane)
        let window = try #require(session.store.moveToNewWindow(pane))
        let overview = Overview()

        #expect(window.send(pane, toVisit: overview.store))
        #expect(session.store.holder(of: pane) === overview.store)
        #expect(window.takeHome(pane))
        #expect(window.surfaces.existingSurface(for: pane) === view)
        #expect(session.store.holder(of: pane) === window)
        #expect(session.released.isEmpty)
    }
}
