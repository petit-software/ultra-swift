import Testing
import AppKit
import CoreGraphics
import Foundation
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout

/// A pane moved into a window of its own, and back: the same view all the way, so the
/// same process. See `LayoutStore.moveToNewWindow`.
@Suite("Pane windows")
@MainActor
struct PaneWindowTests {

    /// A session's canvas in a window, and every pane window it opens in a window of its
    /// own — the way the app shows them.
    @MainActor
    private final class Session {
        let factory = CountingFactory()
        let store: LayoutStore
        let canvas: SplitCanvasView
        var windows: [ObjectIdentifier: (SplitCanvasView, NSWindow)] = [:]
        var released: [PaneID] = []
        var dismissed = 0

        init(_ fixture: LayoutTree.Fixture) {
            let factory = factory
            store = LayoutStore(tree: .fixture(fixture)) { factory.make($0) }
            canvas = Self.host(store)
            store.surfaces.onRelease = { [unowned self] in released.append($0) }
            store.onPaneWindowCreated = { [unowned self] window in
                window.onDismiss = { [unowned self] in dismissed += 1 }
                windows[ObjectIdentifier(window)] = (Self.host(window), NSWindow())
            }
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
            for paneWindow in store.paneWindows {
                guard let (canvas, _) = windows[ObjectIdentifier(paneWindow)] else { continue }
                canvas.sync()
                canvas.layoutSubtreeIfNeeded()
            }
        }
    }

    @Test("a pane moved to a new window keeps its view, and nothing is built or released")
    func moveKeepsTheView() throws {
        let session = Session(.threeAcross)
        session.settle()
        let pane = session.store.tree.paneIDs[1]
        let view = session.store.surfaces.surface(for: pane)

        let window = try #require(session.store.moveToNewWindow(pane))
        session.settle()

        #expect(!session.store.tree.contains(pane))
        #expect(session.store.tree.paneCount == 2)
        #expect(window.tree.paneIDs == [pane])
        #expect(window.isPaneWindow && window.owner === session.store)
        #expect(window.workspaceID == session.store.workspaceID)
        #expect(window.surfaces.existingSurface(for: pane) === view)
        #expect(session.store.surfaces.existingSurface(for: pane) == nil)
        #expect(view.window != nil && view.window !== session.canvas.window,
                "the pane is on screen in its own window")
        #expect(session.factory.builds[pane] == 1)
        #expect(session.released.isEmpty)
        #expect(session.store.holder(of: pane) === window)
    }

    @Test("the last pane of a window cannot leave it, and a pane window sends nothing on")
    func lastPaneStays() throws {
        let single = Session(.single)
        #expect(!single.store.canMoveToNewWindow())
        #expect(single.store.moveToNewWindow() == nil)
        #expect(single.store.paneWindows.isEmpty)

        let session = Session(.grid2x2)
        let window = try #require(session.store.moveToNewWindow(session.store.tree.paneIDs[0]))
        #expect(!window.canMoveToNewWindow())
    }

    @Test("closing the window brings every pane back, still the same view, and the window goes")
    func returnAll() throws {
        let session = Session(.twoAcross)
        session.settle()
        let pane = session.store.tree.paneIDs[0]
        let view = session.store.surfaces.surface(for: pane)
        let window = try #require(session.store.moveToNewWindow(pane))
        session.settle()

        window.returnAllPanes()
        session.settle()

        #expect(session.store.tree.contains(pane))
        #expect(session.store.tree.focused == pane)
        #expect(session.store.surfaces.existingSurface(for: pane) === view)
        #expect(view.window === session.canvas.window)
        #expect(session.store.paneWindows.isEmpty)
        #expect(session.dismissed == 1)
        #expect(session.factory.builds[pane] == 1)
        #expect(session.released.isEmpty)
    }

    @Test("one pane back from a window of two leaves the other in it")
    func moveOneBack() throws {
        let session = Session(.threeAcross)
        let panes = session.store.tree.paneIDs
        let window = try #require(session.store.moveToNewWindow(panes[0]))
        window.split(edge: .right, paneID: panes[0])
        session.settle()
        let second = try #require(window.tree.paneIDs.first { $0 != panes[0] })

        window.moveBackToMainWindow(panes[0])
        session.settle()

        #expect(session.store.tree.contains(panes[0]))
        #expect(window.tree.paneIDs == [second])
        #expect(session.store.paneWindows.count == 1)
        #expect(session.dismissed == 0)
        #expect(session.released.isEmpty)
    }

    @Test("undo puts the pane back exactly where it was; redo sends it out again")
    func undoAndRedo() throws {
        let session = Session(.grid2x2)
        session.settle()
        let before = session.store.tree
        let pane = before.paneIDs[2]
        let view = session.store.surfaces.surface(for: pane)
        try #require(session.store.moveToNewWindow(pane) != nil)
        session.settle()

        session.store.undoManager.undo()
        session.settle()
        #expect(session.store.tree.root == before.root)
        #expect(session.store.surfaces.existingSurface(for: pane) === view)
        #expect(session.store.paneWindows.isEmpty)

        session.store.undoManager.redo()
        session.settle()
        #expect(!session.store.tree.contains(pane))
        #expect(session.store.paneWindows.first?.surfaces.existingSurface(for: pane) === view)
        #expect(session.factory.builds[pane] == 1)
        #expect(session.released.isEmpty)
    }

    @Test("closing a pane in its own window stops it, like closing it anywhere")
    func closeInWindowReleases() throws {
        let session = Session(.threeAcross)
        let pane = session.store.tree.paneIDs[0]
        let window = try #require(session.store.moveToNewWindow(pane))
        window.split(edge: .right, paneID: pane)
        session.settle()

        window.close(pane)
        session.settle()
        #expect(session.released == [pane])
    }

    @Test("closing the session stops the panes in its windows and closes them")
    func sessionCloseReleases() throws {
        let session = Session(.twoAcross)
        let pane = session.store.tree.paneIDs[1]
        try #require(session.store.moveToNewWindow(pane) != nil)
        session.settle()

        session.store.closePaneWindows()
        #expect(session.released == [pane])
        #expect(session.store.paneWindows.isEmpty)
        #expect(session.dismissed == 1)
    }

    @Test("the document carries the pane windows and their panes' records, and restores them")
    func persisted() throws {
        let session = Session(.threeAcross)
        session.settle()
        let pane = session.store.tree.paneIDs[2]
        let window = try #require(session.store.moveToNewWindow(pane))
        window.windowFrame = CGRect(x: 10, y: 20, width: 600, height: 400)

        let document = session.store.document
        #expect(document.isConsistent)
        #expect(document.paneWindows?.map(\.tree.paneIDs) == [[pane]])
        #expect(document.paneWindows?.first?.frame?.rect == CGRect(x: 10, y: 20, width: 600, height: 400))
        #expect(document.record(for: pane) != nil)

        let decoded = try JSONDecoder().decode(WorkspaceDocument.self,
                                               from: JSONEncoder().encode(document))
        #expect(decoded == document)

        let factory = CountingFactory()
        let restored = LayoutStore(tree: decoded.tree) { factory.make($0) }
        var shown: [LayoutStore] = []
        restored.onPaneWindowCreated = { shown.append($0) }
        restored.restorePaneWindows(decoded.paneWindows ?? [])
        #expect(shown.count == 1)
        #expect(shown.first?.tree.paneIDs == [pane])
        #expect(shown.first?.windowFrame == CGRect(x: 10, y: 20, width: 600, height: 400))
    }

    @Test("a document written before pane windows existed still reads, with none")
    func oldDocumentsRead() throws {
        let document = WorkspaceDocument(title: "Old", tree: .fixture(.twoAcross),
                                         panes: Dictionary(uniqueKeysWithValues: LayoutTree.fixture(.twoAcross)
                                            .paneIDs.map { ($0, PaneRecord(kind: .shell, title: "zsh")) }))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        json["paneWindows"] = nil
        let decoded = try JSONDecoder().decode(WorkspaceDocument.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.paneWindows == nil)
        #expect(decoded.isConsistent)
    }

    @Test("the pane's header menu offers the move out, and the move back from a pane window")
    func headerEntry() throws {
        let session = Session(.twoAcross)
        let pane = session.store.tree.paneIDs[0]
        #expect(session.store.surfaces.actions.windowMove(pane)?.title == "Move Pane to New Window")
        let window = try #require(session.store.moveToNewWindow(pane))
        #expect(window.surfaces.actions.windowMove(pane)?.title == "Move Pane Back to Main Window")
        #expect(session.store.surfaces.actions.windowMove(session.store.tree.paneIDs[0]) == nil,
                "the last pane of the main window has nowhere to go")
    }
}
