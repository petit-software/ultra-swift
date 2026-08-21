import Testing
import AppKit
import CoreGraphics
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout

/// Counts how many times content is built for each pane.
@MainActor
final class CountingFactory {
    var builds: [PaneID: Int] = [:]

    func make(_ paneID: PaneID) -> PaneContent {
        builds[paneID, default: 0] += 1
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(paneID.uuidString)
        return PaneContent(view: view, record: PaneRecord(kind: .placeholder, title: "Pane"))
    }
}

@MainActor
private struct Host {
    let canvas: SplitCanvasView
    let store: LayoutStore
    let factory: CountingFactory
    let window: NSWindow

    init(_ fixture: LayoutTree.Fixture) {
        let factory = CountingFactory()
        let store = LayoutStore(tree: .fixture(fixture)) { factory.make($0) }
        let canvas = SplitCanvasView(store: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        canvas.layoutSubtreeIfNeeded()
        self.canvas = canvas
        self.store = store
        self.factory = factory
        self.window = window
    }

    func settle() {
        canvas.sync()
        canvas.layoutSubtreeIfNeeded()
    }
}

/// The executable form of the product's core promise: a pane's view — and therefore, from
/// M2, its PTY — outlives every layout change. See docs/00-OVERVIEW.md.
@Suite("Pane surfaces outlive layout changes")
@MainActor
struct SurfaceLifetimeTests {

    @Test("content is built exactly once, no matter what the layout does")
    func builtOnce() {
        let host = Host(.grid2x2)
        let original = host.store.tree.paneIDs
        let identities = original.map { ObjectIdentifier(host.store.surfaces.surface(for: $0)) }

        host.store.split(edge: .right, paneID: original[0])
        host.store.split(edge: .bottom, paneID: original[1])
        host.store.equalizeAll()
        host.store.toggleZoom()
        host.store.toggleZoom()
        host.store.resizeFocused(.right, by: 40)
        host.settle()

        for (index, paneID) in original.enumerated() {
            #expect(host.factory.builds[paneID] == 1, "pane \(paneID) was rebuilt")
            #expect(ObjectIdentifier(host.store.surfaces.surface(for: paneID)) == identities[index])
        }
    }

    @Test("a watched pane survives 100 random layout operations", arguments: 0..<5)
    func survivesChaos(seed: Int) {
        let host = Host(.single)
        let watched = host.store.tree.focused
        let watchedContent = host.store.surfaces.content(for: watched)
        #expect(watchedContent != nil)

        for _ in 0..<100 {
            switch Int.random(in: 0..<5) {
            case 0, 1:
                let panes = host.store.tree.paneIDs
                if panes.count < 12 {
                    host.store.split(edge: Edge.allCases.randomElement()!,
                                     paneID: panes.randomElement()!)
                }
            case 2:
                let victims = host.store.tree.paneIDs.filter { $0 != watched }
                if let victim = victims.randomElement() {
                    host.store.focus(victim)
                    host.store.closeFocused()
                }
            case 3:
                host.store.resizeFocused(Edge.allCases.randomElement()!, by: 24)
            default:
                host.store.moveFocus(Edge.allCases.randomElement()!)
            }
            host.settle()
            #expect(host.store.tree.validate().isEmpty)
        }

        #expect(host.factory.builds.values.allSatisfy { $0 == 1 }, "a pane was rebuilt")
        #expect(host.store.surfaces.content(for: watched) === watchedContent,
                "the watched pane's content view was replaced")
        #expect(host.store.surfaces.surface(for: watched).superview === host.canvas,
                "the watched pane was detached from the canvas")
    }

    @Test("closing a pane is the only thing that removes its view")
    func closeReleases() {
        let host = Host(.twoAcross)
        let victim = host.store.tree.paneIDs[1]
        let surface = host.store.surfaces.surface(for: victim)
        host.settle()
        #expect(surface.superview === host.canvas)

        host.store.focus(victim)
        host.store.closeFocused()
        host.settle()

        #expect(host.store.surfaces.existingSurface(for: victim) == nil)
        #expect(surface.superview == nil)
    }

    @Test("applied frames match the pure layout function exactly")
    func framesMatchModel() {
        let host = Host(.sidebarMain)
        var metrics = host.store.metrics
        metrics.scale = host.window.backingScaleFactor
        let expected = layout(host.store.tree, in: host.canvas.layoutBounds, metrics: metrics)
        #expect(!expected.frames.isEmpty)

        for (paneID, frame) in expected.frames {
            let surface = host.store.surfaces.surface(for: paneID)
            #expect(surface.frame == frame, "pane \(paneID): \(surface.frame) != \(frame)")
        }
    }

    @Test("a zoomed pane hides its siblings without destroying them")
    func zoomHidesOnly() {
        let host = Host(.grid2x2)
        let panes = host.store.tree.paneIDs
        host.store.focus(panes[2])
        host.store.toggleZoom()
        host.settle()

        #expect(host.store.surfaces.surface(for: panes[2]).isHidden == false)
        for other in panes where other != panes[2] {
            #expect(host.store.surfaces.surface(for: other).isHidden)
            #expect(host.factory.builds[other] == 1)
        }
    }

    @Test("exactly one pane wears the focus border")
    func singleFocus() {
        let host = Host(.grid2x2)
        let panes = host.store.tree.paneIDs
        host.store.focus(panes[2])
        host.settle()

        let focused = panes.filter { host.store.surfaces.surface(for: $0).isFocused }
        #expect(focused == [panes[2]])
    }

    @Test("undo restores the previous tree and reuses the surviving surfaces")
    func undo() {
        let host = Host(.twoAcross)
        let before = host.store.tree
        let survivor = host.store.tree.paneIDs[0]

        host.store.split(edge: .bottom, paneID: survivor)
        host.settle()
        #expect(host.store.tree != before)

        host.store.undoManager.undo()
        host.settle()
        #expect(host.store.tree == before)
        #expect(host.factory.builds[survivor] == 1)
    }

    @Test("a drag commits as a single undo entry")
    func dragIsOneUndoEntry() {
        let host = Host(.twoAcross)
        let before = host.store.tree
        var dragged = before
        let divider = host.canvas.currentResult.dividers.first!
        // Simulate the incremental steps a drag makes.
        for _ in 0..<20 {
            dragged.resize(divider: divider.ref, by: 4,
                           containerSize: divider.containerSize, minPaneSize: 160)
        }
        host.store.commitDrag(dragged)
        host.settle()

        #expect(host.store.tree == dragged)
        host.store.undoManager.undo()
        #expect(host.store.tree == before, "one drag must undo in one step")
    }
}

@Suite("Keyboard target")
@MainActor
struct KeyboardTargetTests {

    /// A pane whose content wraps the thing that actually types — a shell pane's padded
    /// container around its terminal — must still hand the keyboard to the right view.
    /// Getting this wrong leaves the caret in the pane you just split away from.
    final class RefusingContainer: NSView {
        override var acceptsFirstResponder: Bool { false }
    }

    final class Typist: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test("the target is found through a wrapper that refuses focus")
    func findsNestedTarget() {
        let container = RefusingContainer()
        let typist = Typist()
        container.addSubview(typist)
        #expect(SplitCanvasView.keyboardTarget(in: container) === typist)
    }

    @Test("a view that types is its own target")
    func selfIsTarget() {
        let typist = Typist()
        #expect(SplitCanvasView.keyboardTarget(in: typist) === typist)
    }

    @Test("a pane with nothing focusable reports nothing rather than a wrong view")
    func noTarget() {
        let container = RefusingContainer()
        container.addSubview(RefusingContainer())
        #expect(SplitCanvasView.keyboardTarget(in: container) == nil)
    }

    @Test("the search goes as deep as it needs to")
    func deepNesting() {
        let root = RefusingContainer()
        var current: NSView = root
        for _ in 0..<4 {
            let next = RefusingContainer()
            current.addSubview(next)
            current = next
        }
        let typist = Typist()
        current.addSubview(typist)
        #expect(SplitCanvasView.keyboardTarget(in: root) === typist)
    }
}
