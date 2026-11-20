import Testing
import AppKit
import CoreGraphics
import Foundation
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout

/// A pane lifted off the tiling to float over it, and docked again: the same view all
/// the way, so the same process. See `LayoutStore.floatPane`.
@Suite("Floating panes")
@MainActor
struct FloatingPaneTests {

    private func session(_ fixture: LayoutTree.Fixture) -> (LayoutStore, CountingFactory) {
        let factory = CountingFactory()
        let store = LayoutStore(tree: .fixture(fixture)) { factory.make($0) }
        store.canvasBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        return (store, factory)
    }

    @Test("a floated pane keeps its view, leaves the tiling and takes the keyboard")
    func floatKeepsTheView() throws {
        let (store, factory) = session(.threeAcross)
        var opened = 0
        store.onPaneWindowCreated = { _ in opened += 1 }
        let pane = store.tree.paneIDs[1]
        let view = store.surfaces.surface(for: pane)
        let before = store.floatRevision

        let float = try #require(store.floatPane(pane))

        #expect(float.isFloating && float.isPaneWindow && float.owner === store)
        #expect(store.floats.count == 1 && store.floats[0] === float)
        #expect(!store.tree.contains(pane) && store.tree.paneCount == 2)
        #expect(float.tree.paneIDs == [pane])
        #expect(float.surfaces.existingSurface(for: pane) === view)
        #expect(factory.builds[pane] == 1)
        #expect(store.floatRevision != before)
        #expect(store.activeCanvas === float)
        #expect(float.isActiveCanvas && !store.isActiveCanvas)
        #expect(opened == 1, "announced, so the app can give it its pane kinds")
        // In the middle of the canvas, and on it.
        #expect(CGRect(x: 0, y: 0, width: 1200, height: 800).contains(float.floatFrame))
    }

    @Test("docking puts it back in the tiling with the same view, and undo floats it again where it was")
    func dockAndUndo() throws {
        let (store, factory) = session(.threeAcross)
        let pane = store.tree.paneIDs[0]
        let view = store.surfaces.surface(for: pane)
        let float = try #require(store.floatPane(pane))
        float.setFloatFrame(CGRect(x: 100, y: 120, width: 400, height: 300))
        let placed = float.floatFrame
        // Its own undo group, as a later event's would be.
        store.undoManager.removeAllActions()

        float.dockPane()

        #expect(store.floats.isEmpty)
        #expect(store.tree.contains(pane) && store.tree.paneCount == 3)
        #expect(store.surfaces.existingSurface(for: pane) === view)
        #expect(store.activeCanvas === store && store.isActiveCanvas)
        #expect(factory.builds[pane] == 1)

        store.undoManager.undo()
        let again = try #require(store.floats.first)
        #expect(again.tree.paneIDs == [pane])
        #expect(again.floatFrame == placed)
        #expect(again.surfaces.existingSurface(for: pane) === view)
    }

    @Test("undoing a float puts the pane back exactly where it was in the tiling")
    func undoFloat() throws {
        let (store, _) = session(.threeAcross)
        let tree = store.tree
        _ = try #require(store.floatPane(store.tree.paneIDs[1]))
        store.undoManager.undo()
        #expect(store.tree.root == tree.root)
        #expect(store.floats.isEmpty)
    }

    @Test("the last pane of a canvas does not float, and a floating pane does not float again")
    func whatCannotFloat() throws {
        let (single, _) = session(.single)
        #expect(!single.canFloat())
        let (store, _) = session(.threeAcross)
        let float = try #require(store.floatPane())
        #expect(!float.canFloat())
        #expect(float.windowMove(for: float.tree.focused) == nil)
        #expect(float.floatMove(for: float.tree.focused)?.title == "Dock Pane")
        #expect(store.floatMove(for: store.tree.focused)?.title == "Float Pane")
    }

    @Test("focusing a pane under a float gives the canvas the keyboard back, and the float takes it again")
    func keyboardFollowsFocus() throws {
        let (store, _) = session(.threeAcross)
        let float = try #require(store.floatPane(store.tree.paneIDs[2]))
        #expect(store.activeCanvas === float)
        store.focus(store.tree.paneIDs[0])
        #expect(store.activeCanvas === store)
        float.focus(float.tree.focused)
        #expect(store.activeCanvas === float)
    }

    @Test("a float's header drag moves it, and it is kept within reach of the canvas")
    func dragMoves() throws {
        let (store, _) = session(.threeAcross)
        let float = try #require(store.floatPane())
        float.setFloatFrame(CGRect(x: 100, y: 100, width: 400, height: 300))
        let pane = float.tree.focused
        let drag = try #require(float.surfaces.actions.floatDrag)
        drag(pane, CGSize(width: 50, height: 20), false)
        drag(pane, CGSize(width: 150, height: 60), true)
        #expect(float.floatFrame == CGRect(x: 250, y: 160, width: 400, height: 300))
        // Thrown far past every edge, it comes to rest 16 points inside the canvas.
        drag(pane, CGSize(width: 5000, height: 5000), true)
        #expect(float.floatFrame == CGRect(x: 1200 - 16 - 400, y: 800 - 16 - 300, width: 400, height: 300))
        drag(pane, CGSize(width: -9000, height: -9000), true)
        #expect(float.floatFrame == CGRect(x: 16, y: 16, width: 400, height: 300))
        #expect(store.surfaces.actions.floatDrag == nil, "a tiled pane's header picks the pane up")
    }

    @Test("a frame is never smaller than the least a float can be, and always 16 points inside the canvas")
    func fitting() {
        let canvas = CGRect(x: 0, y: 40, width: 800, height: 500)
        let room = canvas.insetBy(dx: 16, dy: 16)
        let small = LayoutStore.floatFrame(CGRect(x: 10, y: 50, width: 20, height: 20), fitting: canvas)
        #expect(small.size == LayoutStore.minFloatSize)
        let large = LayoutStore.floatFrame(CGRect(x: 0, y: 40, width: 4000, height: 4000), fitting: canvas)
        #expect(large == room)
        let above = LayoutStore.floatFrame(CGRect(x: 100, y: -300, width: 300, height: 200), fitting: canvas)
        #expect(above.minY == 56, "never up under the window's title bar")
        let right = LayoutStore.floatFrame(CGRect(x: 700, y: 100, width: 300, height: 200), fitting: canvas)
        #expect(right.maxX == 784)
        let inside = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(LayoutStore.floatFrame(inside, fitting: canvas) == inside)
    }

    @Test("held, a float gives a quarter of the way past an edge; let go, it is back inside")
    func pullsPastAnEdge() throws {
        let (store, _) = session(.threeAcross)
        let float = try #require(store.floatPane())
        float.setFloatFrame(CGRect(x: 100, y: 100, width: 400, height: 300))
        let pane = float.tree.focused
        let drag = try #require(float.surfaces.actions.floatDrag)
        // 316 is as far left as it rests; pulled 200 further, it gives 50.
        drag(pane, CGSize(width: -284, height: 0), false)
        #expect(float.isFloatHeld)
        #expect(abs(float.floatFrame.minX - (16 - 50)) < 0.001)
        drag(pane, CGSize(width: -284, height: 0), true)
        #expect(!float.isFloatHeld)
        #expect(float.floatFrame.origin == CGPoint(x: 16, y: 100))
    }

    @Test("a floating pane is written to the document as one, and restored floating")
    func roundTrip() throws {
        let (store, _) = session(.threeAcross)
        let pane = store.tree.paneIDs[1]
        let float = try #require(store.floatPane(pane))
        float.setFloatFrame(CGRect(x: 90, y: 110, width: 420, height: 310))
        _ = try #require(store.moveToNewWindow(store.tree.paneIDs[0]))

        let layouts = try #require(store.document.paneWindows)
        #expect(layouts.count == 2)
        let floating = try #require(layouts.first { $0.floats == true })
        #expect(floating.tree.paneIDs == [pane])
        #expect(floating.frame?.rect == CGRect(x: 90, y: 110, width: 420, height: 310))
        #expect(layouts.filter { $0.floats == nil }.count == 1)

        let data = try JSONEncoder().encode(store.document)
        let document = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
        let factory = CountingFactory()
        let restored = LayoutStore(tree: document.tree) { factory.make($0) }
        var announced = 0
        restored.onPaneWindowCreated = { _ in announced += 1 }
        restored.restorePaneWindows(document.paneWindows ?? [])
        #expect(restored.floats.count == 1)
        #expect(restored.floats.first?.floatFrame == CGRect(x: 90, y: 110, width: 420, height: 310))
        #expect(restored.paneWindows.filter { !$0.isFloating }.count == 1)
    }

    @Test("a document from before panes could float decodes, with nothing floating")
    func oldDocument() throws {
        let json = #"{"tree":\#(String(data: try JSONEncoder().encode(LayoutTree.fixture(.single)), encoding: .utf8)!)}"#
        let layout = try JSONDecoder().decode(PaneWindowLayout.self, from: Data(json.utf8))
        #expect(layout.floats == nil && layout.frame == nil)
    }

    @Test("the keyboard goes round the tiling and every floating pane, and back")
    func cycle() throws {
        let (store, _) = session(.grid2x2)
        #expect(!store.canCycleCanvas)
        let first = try #require(store.floatPane(store.tree.paneIDs[0]))
        store.focus(store.tree.focused)
        let second = try #require(store.floatPane(store.tree.paneIDs[0]))
        store.focus(store.tree.focused)
        #expect(store.activeCanvas === store && store.canCycleCanvas && first.canCycleCanvas)

        store.cycleCanvas()
        let one = store.activeCanvas
        #expect(one === first)
        one.cycleCanvas()
        #expect(store.activeCanvas === second)
        second.cycleCanvas()
        #expect(store.activeCanvas === store)
    }

    @Test("a floating pane's header band moves it; a tiled pane's picks the pane up")
    func headerBandMoves() throws {
        let store = LayoutStore.placeholders(.threeAcross)
        store.assumeCanvasBounds(CGRect(x: 0, y: 0, width: 1000, height: 640))
        let float = try #require(store.floatPane())
        float.setFloatFrame(CGRect(x: 300, y: 200, width: 460, height: 300))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let canvas = SplitCanvasView(store: float)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let found = view as? T { return found }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let surface = try #require(float.surfaces.existingSurface(for: float.tree.focused))
        let handle = try #require(find(PaneDragHandleView.self, in: surface))
        let start = CGPoint(x: 500, y: 600)
        handle.mouseDown(with: event(.leftMouseDown, start))
        handle.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: start.x + 10, y: start.y)))
        #expect(float.floatFrame.origin == CGPoint(x: 310, y: 200))
        // The window's y runs up: 40 down the screen is 40 down the canvas.
        handle.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: start.x + 60, y: start.y - 40)))
        handle.mouseUp(with: event(.leftMouseUp, CGPoint(x: start.x + 60, y: start.y - 40)))
        #expect(float.floatFrame == CGRect(x: 360, y: 240, width: 460, height: 300))
    }
}
