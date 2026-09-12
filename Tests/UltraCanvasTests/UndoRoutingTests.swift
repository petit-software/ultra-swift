import Testing
import AppKit
@testable import UltraCanvas
@testable import UltraLayout

/// ⌘Z goes to the text when text is being edited, and to the layout otherwise.
///
/// The bug this pins: with Edit ▸ Undo wired straight to the layout's stack, ⌘Z in a
/// freshly opened editor pane undid the split that opened it — the pane closed, and the
/// typing stayed.
@Suite("Undo routing")
@MainActor
struct UndoRoutingTests {

    private final class Plain: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func makeWindow() -> (NSWindow, LayoutStore, SplitCanvasView) {
        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(.threeAcross)) { factory.makeContent(for: $0) }
        let canvas = SplitCanvasView(store: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = canvas
        return (window, store, canvas)
    }

    @Test("a plain view with the keyboard leaves ⌘Z to the layout")
    func plainViewGoesToLayout() {
        let (window, store, canvas) = makeWindow()
        let plain = Plain(frame: canvas.bounds)
        canvas.addSubview(plain)
        window.makeFirstResponder(plain)
        #expect(UndoRouting.manager(for: store, firstResponder: window.firstResponder)
                === store.undoManager)
    }

    @Test("nothing focused at all leaves ⌘Z to the layout")
    func nothingFocusedGoesToLayout() {
        let (_, store, _) = makeWindow()
        #expect(UndoRouting.manager(for: store, firstResponder: nil) === store.undoManager)
    }

    /// The editor. Its own manager, from its delegate, is what ⌘Z must reach — never the
    /// layout's stack, whatever is on it.
    @Test("a text view with the keyboard gets its own undo manager")
    func textViewGetsItsOwn() {
        let (window, store, canvas) = makeWindow()
        let own = UndoManager()
        let delegate = OwnManagerDelegate(manager: own)
        let text = NSTextView(frame: canvas.bounds)
        text.allowsUndo = true
        text.delegate = delegate
        canvas.addSubview(text)
        window.makeFirstResponder(text)
        let chosen = UndoRouting.manager(for: store, firstResponder: window.firstResponder)
        #expect(chosen === own)
        #expect(chosen !== store.undoManager)
    }

    /// A text view without a delegate-provided manager falls through to the window's — a
    /// SwiftUI `TextField`'s field editor is exactly this. Still not the layout's.
    @Test("a text view on the window's manager is still not the layout's")
    func textViewOnWindowManager() {
        let (window, store, canvas) = makeWindow()
        let text = NSTextView(frame: canvas.bounds)
        text.allowsUndo = true
        canvas.addSubview(text)
        window.makeFirstResponder(text)
        let chosen = UndoRouting.manager(for: store, firstResponder: window.firstResponder)
        #expect(chosen != nil)
        #expect(chosen !== store.undoManager)
    }

    /// A field with nothing to take back is a beep, not a closed pane.
    @Test("a text view with no history yields nothing rather than the layout")
    func textViewWithoutHistoryYieldsNothing() {
        let (window, store, canvas) = makeWindow()
        let text = NSTextView(frame: canvas.bounds)
        text.allowsUndo = false
        text.delegate = OwnManagerDelegate(manager: nil)
        canvas.addSubview(text)
        window.makeFirstResponder(text)
        #expect(UndoRouting.manager(for: store, firstResponder: window.firstResponder) == nil)
    }
}

@MainActor
private final class OwnManagerDelegate: NSObject, NSTextViewDelegate {
    let manager: UndoManager?
    init(manager: UndoManager?) { self.manager = manager }
    nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
        MainActor.assumeIsolated { manager }
    }
}
