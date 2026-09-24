import Testing
import AppKit
@testable import UltraCanvas
@testable import UltraDesign

/// Where the keyboard goes inside a pane. Both rules exist because of a pane with two places
/// to type — a browser's address field and its page.
@Suite("A pane's keyboard target")
@MainActor
struct PaneKeyboardTargetTests {

    /// A view that takes the keyboard, like a field or a web view.
    private final class Typable: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class Provider: NSView, KeyboardTargetProviding {
        var preferredKeyboardTarget: NSView?
    }

    @Test("without a preference, the first view that takes the keyboard wins")
    func firstTypable() {
        let content = NSView()
        let field = Typable(), page = Typable()
        content.addSubview(field)
        content.addSubview(page)
        #expect(SplitCanvasView.keyboardTarget(in: content) === field)
    }

    @Test("a pane's own preference wins over the order of its views")
    func preferenceWins() {
        let content = Provider()
        let field = Typable(), page = Typable()
        content.addSubview(field)
        content.addSubview(page)
        content.preferredKeyboardTarget = page
        #expect(SplitCanvasView.keyboardTarget(in: content) === page)
        // No preference — an empty browser pane — falls back to the first field.
        content.preferredKeyboardTarget = nil
        #expect(SplitCanvasView.keyboardTarget(in: content) === field)
    }

    @Test("a preference for a view that is not in the pane is ignored")
    func preferenceMustBeInside() {
        let content = Provider()
        let field = Typable()
        content.addSubview(field)
        content.preferredKeyboardTarget = Typable()
        #expect(SplitCanvasView.keyboardTarget(in: content) === field)
    }

    @Test("a first responder anywhere in the pane counts as the pane having the keyboard")
    func insidePane() {
        let content = NSView(), other = NSView()
        let field = Typable(), page = Typable()
        content.addSubview(field)
        content.addSubview(page)
        #expect(SplitCanvasView.responder(page, isInside: content))
        #expect(SplitCanvasView.responder(field, isInside: content))
        #expect(!SplitCanvasView.responder(other, isInside: content))
        #expect(!SplitCanvasView.responder(nil, isInside: content))
    }

    /// At runtime a field editor's delegate IS the text field it edits; Swift's overlay just
    /// does not declare the conformance, so the test has to.
    private final class EditedField: NSTextField, NSTextViewDelegate {}

    @Test("a field editor answers for the field it is editing")
    func fieldEditor() {
        let content = NSView()
        let field = EditedField()
        content.addSubview(field)
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.delegate = field
        #expect(SplitCanvasView.responder(editor, isInside: content))
    }
}
