import AppKit
import SwiftUI
import UltraDesign

/// A plain-text editing surface with line numbers.
///
/// `NSTextView` rather than SwiftUI's `TextEditor`, for two reasons that matter for code:
/// `TextEditor` cannot carry a line-number ruler, and it inherits the system's smart
/// substitutions — curly quotes and em dashes silently replacing what you typed, which is a
/// bug generator in a config file.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    /// Asked once, as the view is made: whether it should take the keyboard when it lands
    /// in a window. A question rather than a flag so the answer can be "yes, this once" —
    /// see `EditorDocument.claimInitialFocus`.
    var claimsFocus: () -> Bool = { false }
    var onSave: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // Pinned, for the same reason `ShellTerminalView` pins it: with "Show scroll bars:
        // Always" — which is what a user gets the moment a mouse is attached — macOS makes
        // every scroller `.legacy`, and a legacy scroller RESERVES width instead of floating
        // over the content. That is a permanent grey gutter down a pane that is already as
        // narrow as the user made it, and `autohidesScrollers` does not prevent it.
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = SaveAwareTextView()
        textView.onSave = onSave
        textView.focusesOnAppear = claimsFocus()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(Token.Colour.label)
        textView.insertionPointColor = NSColor(Token.Colour.accent)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // Every one of these turns a helpful prose feature into a code corrupter.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        // Horizontal scrolling off: wrapping keeps long lines reachable in a narrow pane.
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView

        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? SaveAwareTextView else { return }
        textView.onSave = onSave
        textView.isEditable = isEditable
        // Only when it genuinely differs: assigning the string resets the selection, so
        // doing it on every update would fight the cursor on every keystroke.
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            // The text was replaced from OUTSIDE — another file in this pane, or a reload
            // from disk — and none of that went through the undo manager. Entries still on
            // the stack belong to text that is no longer there; applying one would splice
            // old characters into the new file at ranges that mean nothing now.
            context.coordinator.undoManager.removeAllActions()
            textView.setSelectedRange(NSRange(location: min(selected.location, text.utf16.count),
                                              length: 0))
            context.coordinator.ruler?.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: CodeTextView
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?
        /// This view's own history. Without one, a text view registers into the WINDOW's
        /// undo manager, which every text field in every tile shares — so ⌘Z in a file
        /// could take back a rename typed into the todo list an hour ago. `UndoRouting`
        /// hands ⌘Z to whatever manager the focused text view reports, and this is it.
        let undoManager = UndoManager()

        init(_ parent: CodeTextView) { self.parent = parent }

        nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
            MainActor.assumeIsolated { undoManager }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            ruler?.needsDisplay = true
        }
    }
}

/// Takes ⌘S itself. The app's ⌘S saves the LAYOUT, and while you are typing in a file that
/// is not what the keystroke means.
final class SaveAwareTextView: NSTextView {
    var onSave: () -> Void = {}
    var focusesOnAppear = false

    /// A turn later, because the view is put in the window in the middle of a layout pass,
    /// and the canvas settles its own focus in the same pass — asking now would be asking
    /// first and being overruled.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusesOnAppear, window != nil else { return }
        focusesOnAppear = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            onSave()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Line numbers down the left edge.
///
/// Drawn per visible line rather than per line in the file: a 50,000-line file must cost the
/// same to scroll as a 50-line one.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(Token.Colour.tertiaryLabel),
        ]

        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                          actualGlyphRange: nil)
        let text = textView.string as NSString

        // The line number of the first visible line, counted once.
        var lineNumber = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characterRange.location),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        text.enumerateSubstrings(in: characterRange,
                                 options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let rect = layoutManager.boundingRect(
                forGlyphRange: layoutManager.glyphRange(forCharacterRange: range,
                                                        actualCharacterRange: nil),
                in: container)
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = rect.minY + textView.textContainerInset.height
                - textView.visibleRect.minY + (rect.height - size.height) / 2
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 6, y: y),
                       withAttributes: attributes)
            lineNumber += 1
        }
    }
}
